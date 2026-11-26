// Off-screen pages (approach 5, prototype): CEF windowless rendering with
// shared textures. Chromium draws each frame into an IOSurface of its frame
// sink video capturer (CefVideoConsumerOSR) and hands it to
// CefRenderHandler::OnAcceleratedPaint; the surface goes back to Chromium's
// pool when that call returns, so the shim copies it (one Metal blit, waited
// for) into an IOSurface of its own and gives that to the host, which shows
// it as a layer's contents. Input comes back through CefBrowserHost.
//
// A windowless browser is Alloy style (CEF refuses Chrome style with
// windowless rendering, browser_host_create.cc MaybeSetWindowInfo): no
// Browser, no tab strip, no Chrome window. See approaches/osr in cmuxterm-hq.

#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <mach/mach_time.h>

#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "include/cef_drag_data.h"
#include "include/cef_render_handler.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace cmux_shim {

namespace {

bool g_enabled = false;
int g_flags = 0;  // bit 0: external begin frames
cmux_shim_osr_handlers g_handlers = {};
void* g_ctx = nullptr;

struct Counters {
  uint64_t frames = 0;
  uint64_t letterboxed = 0;
  uint64_t blit_us = 0;
  uint64_t refreshes = 0;
  uint64_t popup_frames = 0;
  uint64_t blit_failures = 0;
  uint64_t surfaces_made = 0;
};
Counters g_counters;

std::set<int>& offscreen_browsers() {
  static std::set<int> set;
  return set;
}

// The operation each browser's page takes for the drag over it (UpdateDragCursor).
std::map<int, int>& drag_operations() {
  static std::map<int, int> map;
  return map;
}

uint64_t NowMicros() {
  static mach_timebase_info_data_t base = [] {
    mach_timebase_info_data_t b;
    mach_timebase_info(&b);
    return b;
  }();
  return mach_absolute_time() * base.numer / base.denom / 1000;
}

id<MTLDevice> Device() {
  static id<MTLDevice> device = MTLCreateSystemDefaultDevice();  // kept for the process
  return device;
}

id<MTLCommandQueue> Queue() {
  static id<MTLCommandQueue> queue = [Device() newCommandQueue];  // kept for the process
  return queue;
}

// The host's surfaces of one browser and paint type. A surface Core Animation
// still shows (IOSurfaceIsInUse) or the one handed out last is never written.
struct Ring {
  std::vector<IOSurfaceRef> surfaces;
  IOSurfaceRef last = nullptr;
};

std::map<std::pair<int, int>, Ring>& rings() {
  static std::map<std::pair<int, int>, Ring> map;
  return map;
}

IOSurfaceRef MakeSurface(int width, int height, OSType format) {
  const size_t row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, static_cast<size_t>(width) * 4);
  NSDictionary* properties = @{
    (id)kIOSurfaceWidth : @(width),
    (id)kIOSurfaceHeight : @(height),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(row),
    (id)kIOSurfacePixelFormat : @(format),
  };
  IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
  if (surface) g_counters.surfaces_made++;
  return surface;
}

IOSurfaceRef TakeSurface(int browser_id, int type, int width, int height, OSType format) {
  Ring& ring = rings()[{browser_id, type}];
  IOSurfaceRef found = nullptr;
  std::vector<IOSurfaceRef> keep;
  for (IOSurfaceRef surface : ring.surfaces) {
    const bool fits = static_cast<int>(IOSurfaceGetWidth(surface)) == width &&
                      static_cast<int>(IOSurfaceGetHeight(surface)) == height &&
                      IOSurfaceGetPixelFormat(surface) == format;
    const bool busy = surface == ring.last || IOSurfaceIsInUse(surface);
    if (!found && fits && !busy) {
      found = surface;
      keep.push_back(surface);
    } else if (!fits && !busy) {
      CFRelease(surface);  // an old size nobody shows
    } else {
      keep.push_back(surface);
    }
  }
  ring.surfaces = keep;
  if (!found) {
    found = MakeSurface(width, height, format);
    if (!found) return nullptr;
    ring.surfaces.push_back(found);
  }
  ring.last = found;
  return found;
}

void DropRings(int browser_id) {
  for (int type = 0; type < 2; ++type) {
    auto it = rings().find({browser_id, type});
    if (it == rings().end()) continue;
    for (IOSurfaceRef surface : it->second.surfaces) CFRelease(surface);
    rings().erase(it);
  }
}

// Copies `rect` of `source` into a host surface; waits for the GPU, since the
// source goes back to Chromium's pool when OnAcceleratedPaint returns.
IOSurfaceRef CopySurface(int browser_id, int type, IOSurfaceRef source, const CefRect& rect) {
  const OSType format = IOSurfaceGetPixelFormat(source);
  const MTLPixelFormat pixel = format == 'RGBA' ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatBGRA8Unorm;
  IOSurfaceRef target = TakeSurface(browser_id, type, rect.width, rect.height, format);
  if (!target) return nullptr;
  MTLTextureDescriptor* source_desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel
                                                         width:IOSurfaceGetWidth(source)
                                                        height:IOSurfaceGetHeight(source)
                                                     mipmapped:NO];
  source_desc.usage = MTLTextureUsageShaderRead;
  source_desc.storageMode = MTLStorageModeShared;
  MTLTextureDescriptor* target_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel
                                                                                          width:rect.width
                                                                                         height:rect.height
                                                                                      mipmapped:NO];
  target_desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  target_desc.storageMode = MTLStorageModeShared;
  id<MTLTexture> from = [Device() newTextureWithDescriptor:source_desc iosurface:source plane:0];
  id<MTLTexture> to = [Device() newTextureWithDescriptor:target_desc iosurface:target plane:0];
  if (!from || !to) {
    [from release];
    [to release];
    return nullptr;
  }
  id<MTLCommandBuffer> command = [Queue() commandBuffer];
  id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
  [blit copyFromTexture:from
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(rect.x, rect.y, 0)
             sourceSize:MTLSizeMake(rect.width, rect.height, 1)
              toTexture:to
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
  [command commit];
  [command waitUntilCompleted];
  const bool ok = command.status == MTLCommandBufferStatusCompleted;
  [from release];
  [to release];
  return ok ? target : nullptr;
}

class OffscreenRenderHandler : public CefRenderHandler {
 public:
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    int width = 0, height = 0;
    if (g_handlers.view_rect) g_handlers.view_rect(g_ctx, browser->GetIdentifier(), &width, &height);
    rect = CefRect(0, 0, std::max(width, 1), std::max(height, 1));
  }

  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) override {
    if (!g_handlers.screen_info) return false;
    float scale = 0;
    int rect[4] = {0, 0, 0, 0};
    int available[4] = {0, 0, 0, 0};
    if (!g_handlers.screen_info(g_ctx, browser->GetIdentifier(), &scale, rect, available) || scale <= 0) return false;
    info.device_scale_factor = scale;
    info.depth = 24;
    info.depth_per_component = 8;
    info.is_monochrome = 0;
    info.rect = CefRect(rect[0], rect[1], rect[2], rect[3]);
    info.available_rect = CefRect(available[0], available[1], available[2], available[3]);
    return true;
  }

  bool GetScreenPoint(CefRefPtr<CefBrowser> browser, int view_x, int view_y, int& screen_x, int& screen_y) override {
    if (!g_handlers.screen_point) return false;
    return g_handlers.screen_point(g_ctx, browser->GetIdentifier(), view_x, view_y, &screen_x, &screen_y) != 0;
  }

  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
    if (g_handlers.popup_show) g_handlers.popup_show(g_ctx, browser->GetIdentifier(), show ? 1 : 0);
  }

  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override {
    if (g_handlers.popup_rect) {
      g_handlers.popup_rect(g_ctx, browser->GetIdentifier(), rect.x, rect.y, rect.width, rect.height);
    }
  }

  // Shared textures are on for every off-screen browser; the software path is
  // unused (a frame that comes here is dropped and counted).
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList&, const void*, int, int) override {
    g_counters.blit_failures++;
  }

  void OnAcceleratedPaint(CefRefPtr<CefBrowser> browser, PaintElementType type, const RectList&,
                          const CefAcceleratedPaintInfo& info) override {
    const int id = browser->GetIdentifier();
    IOSurfaceRef source = static_cast<IOSurfaceRef>(info.shared_texture_io_surface);
    if (!source || !g_handlers.frame) return;
    const cef_accelerated_paint_info_common_t& extra = info.extra;
    CefRect visible(extra.visible_rect.x, extra.visible_rect.y, extra.visible_rect.width, extra.visible_rect.height);
    if (visible.IsEmpty()) visible = CefRect(0, 0, IOSurfaceGetWidth(source), IOSurfaceGetHeight(source));
    // The capturer keeps its resolution until the page's first frame at a new
    // size activated (CefVideoConsumerOSR::SizeChanged, fixed aspect ratio):
    // a frame between is the page scaled into the old size (letterboxed, or
    // scaled whole when the aspect matched), which must never show. It goes
    // to the host marked, without pixels; the host keeps its last frame and
    // may ask for a refresh (cmux_shim_osr_invalidate).
    const CefRect content(extra.content_rect.x, extra.content_rect.y, extra.content_rect.width,
                          extra.content_rect.height);
    const bool scaled = extra.has_source_size &&
                        (extra.source_size.width != visible.width || extra.source_size.height != visible.height);
    const bool letterboxed =
        scaled || (!content.IsEmpty() && (content.width != visible.width || content.height != visible.height));
    cmux_shim_osr_frame frame = {};
    frame.type = type == PET_POPUP ? 1 : 0;
    frame.source_width = extra.has_source_size ? extra.source_size.width : 0;
    frame.source_height = extra.has_source_size ? extra.source_size.height : 0;
    frame.capture_counter = extra.capture_counter;
    frame.timestamp_us = static_cast<int64_t>(extra.timestamp);
    if (letterboxed) {
      g_counters.letterboxed++;
      frame.letterboxed = 1;
      frame.width = content.width;
      frame.height = content.height;
      g_handlers.frame(g_ctx, id, &frame);
      return;
    }
    const uint64_t started = NowMicros();
    IOSurfaceRef copy = CopySurface(id, frame.type, source, visible);
    g_counters.blit_us += NowMicros() - started;
    if (!copy) {
      g_counters.blit_failures++;
      return;
    }
    g_counters.frames++;
    if (frame.type == 1) g_counters.popup_frames++;
    frame.io_surface = copy;
    frame.width = visible.width;
    frame.height = visible.height;
    g_handlers.frame(g_ctx, id, &frame);
  }

  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser> browser, const CefRange& range,
                                    const RectList& character_bounds) override {
    if (!g_handlers.ime_range) return;
    std::vector<int> rects;
    rects.reserve(character_bounds.size() * 4);
    for (const CefRect& r : character_bounds) {
      rects.push_back(r.x);
      rects.push_back(r.y);
      rects.push_back(r.width);
      rects.push_back(r.height);
    }
    g_handlers.ime_range(g_ctx, browser->GetIdentifier(), static_cast<int>(range.from), static_cast<int>(range.to),
                         rects.data(), static_cast<int>(character_bounds.size()));
  }

  // A drag that starts in the page (a link, an image, selected text) would
  // need an NSDraggingSession run for Chromium; not built in the prototype.
  bool StartDragging(CefRefPtr<CefBrowser>, CefRefPtr<CefDragData>, DragOperationsMask, int, int) override {
    return false;
  }

  void UpdateDragCursor(CefRefPtr<CefBrowser> browser, DragOperation operation) override {
    drag_operations()[browser->GetIdentifier()] = static_cast<int>(operation);
  }

 private:
  IMPLEMENT_REFCOUNTING(OffscreenRenderHandler);
};

CefRefPtr<CefBrowserHost> OffscreenHost(int browser_id) {
  if (!offscreen_browsers().count(browser_id)) return nullptr;
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  return browser ? browser->GetHost() : nullptr;
}

CefRange RangeOf(int from, int to) {
  if (from < 0 || to < 0) return CefRange::InvalidRange();
  return CefRange(static_cast<uint32_t>(from), static_cast<uint32_t>(to));
}

}  // namespace

bool OffscreenEnabled() {
  return g_enabled;
}

CefRefPtr<CefRenderHandler> OffscreenRenderHandlerInstance() {
  if (!g_enabled) return nullptr;
  static CefRefPtr<CefRenderHandler> handler = new OffscreenRenderHandler();
  return handler;
}

bool IsOffscreenBrowser(int browser_id) {
  return offscreen_browsers().count(browser_id) != 0;
}

void NoteOffscreenBrowser(int browser_id, bool offscreen) {
  if (offscreen) {
    offscreen_browsers().insert(browser_id);
  } else {
    offscreen_browsers().erase(browser_id);
    drag_operations().erase(browser_id);
    DropRings(browser_id);
  }
}

bool OffscreenCursorChanged(int browser_id, void* cursor) {
  if (!IsOffscreenBrowser(browser_id) || !g_handlers.cursor) return false;
  g_handlers.cursor(g_ctx, browser_id, cursor);
  return true;
}

int OffscreenFrameRate() {
  static int rate = [] {
    const char* value = getenv("CMUX_OSR_FRAME_RATE");
    int parsed = value ? atoi(value) : 0;
    return parsed >= 1 && parsed <= 240 ? parsed : 120;
  }();
  return rate;
}

void MakeOffscreenWindowInfo(CefWindowInfo& info, void* parent_view) {
  info = CefWindowInfo();
  info.SetAsWindowless(static_cast<CefWindowHandle>(parent_view));
  info.shared_texture_enabled = 1;
  info.external_begin_frame_enabled = (g_flags & 1) ? 1 : 0;
}

}  // namespace cmux_shim

extern "C" {

void cmux_shim_osr_enable(int enabled, int flags) {
  g_enabled = enabled != 0;
  g_flags = flags;
}

void cmux_shim_osr_set_handlers(const cmux_shim_osr_handlers* handlers, void* ctx) {
  g_handlers = handlers ? *handlers : cmux_shim_osr_handlers{};
  g_ctx = ctx;
}

int cmux_shim_osr_create(int request, void* parent_view, int width, int height, const char* url,
                         const char* profile_cache_path, int frame_rate) {
  if (!g_enabled || stopping()) return 0;
  CefWindowInfo info;
  MakeOffscreenWindowInfo(info, parent_view);
  info.bounds = CefRect(0, 0, width, height);
  CefBrowserSettings settings;
  settings.background_color = BackgroundColor();
  settings.windowless_frame_rate = frame_rate >= 1 && frame_rate <= 240 ? frame_rate : OffscreenFrameRate();
  settings.chrome_status_bubble = STATE_DISABLED;
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path ? profile_cache_path : "");
  return CefBrowserHost::CreateBrowser(info, MakeClient(request), url ? url : "", settings, nullptr, context) ? 1 : 0;
}

int cmux_shim_osr_is_offscreen(int browser_id) {
  return IsOffscreenBrowser(browser_id) ? 1 : 0;
}

void cmux_shim_osr_was_resized(int browser_id) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->WasResized();
}

void cmux_shim_osr_was_hidden(int browser_id, int hidden) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->WasHidden(hidden != 0);
}

void cmux_shim_osr_screen_info_changed(int browser_id) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->NotifyScreenInfoChanged();
}

void cmux_shim_osr_invalidate(int browser_id) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) {
    g_counters.refreshes++;
    host->Invalidate(PET_VIEW);
  }
}

void cmux_shim_osr_set_frame_rate(int browser_id, int frame_rate) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->SetWindowlessFrameRate(frame_rate);
}

void cmux_shim_osr_begin_frame(int browser_id) {
  if (!(g_flags & 1)) return;
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->SendExternalBeginFrame();
}

int cmux_shim_osr_drag(int browser_id, int kind, int x, int y, uint32_t modifiers, const char* const* paths,
                       int count, int allowed_ops) {
  CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id);
  if (!host) return 0;
  CefMouseEvent event;
  event.x = x;
  event.y = y;
  event.modifiers = modifiers;
  const auto ops = static_cast<cef_drag_operations_mask_t>(allowed_ops);
  switch (kind) {
    case 0: {
      drag_operations()[browser_id] = 0;
      CefRefPtr<CefDragData> data = CefDragData::Create();
      for (int i = 0; paths && i < count; ++i) {
        if (!paths[i]) continue;
        const std::string path = paths[i];
        const size_t slash = path.find_last_of('/');
        data->AddFile(path, slash == std::string::npos ? path : path.substr(slash + 1));
      }
      host->DragTargetDragEnter(data, event, ops);
      break;
    }
    case 1:
      host->DragTargetDragOver(event, ops);
      break;
    case 2:
      host->DragTargetDragLeave();
      break;
    case 3:
      host->DragTargetDrop(event);
      break;
    default:
      break;
  }
  auto it = drag_operations().find(browser_id);
  return it == drag_operations().end() ? 0 : it->second;
}

void cmux_shim_osr_mouse(int browser_id, int kind, int x, int y, uint32_t modifiers, int button, int click_count) {
  CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id);
  if (!host) return;
  CefMouseEvent event;
  event.x = x;
  event.y = y;
  event.modifiers = modifiers;
  const CefBrowserHost::MouseButtonType type =
      button == 2 ? MBT_RIGHT : button == 1 ? MBT_MIDDLE : MBT_LEFT;
  switch (kind) {
    case 0:
      host->SendMouseMoveEvent(event, false);
      break;
    case 1:
      host->SendMouseMoveEvent(event, true);
      break;
    case 2:
      host->SendMouseClickEvent(event, type, false, std::max(1, click_count));
      break;
    case 3:
      host->SendMouseClickEvent(event, type, true, std::max(1, click_count));
      break;
    default:
      break;
  }
}

void cmux_shim_osr_wheel(int browser_id, int x, int y, uint32_t modifiers, int delta_x, int delta_y) {
  CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id);
  if (!host) return;
  CefMouseEvent event;
  event.x = x;
  event.y = y;
  event.modifiers = modifiers;
  host->SendMouseWheelEvent(event, delta_x, delta_y);
}

void cmux_shim_osr_key(int browser_id, int type, uint32_t modifiers, int native_key_code, uint16_t character,
                       uint16_t unmodified_character) {
  CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id);
  if (!host) return;
  CefKeyEvent event;
  event.type = static_cast<cef_key_event_type_t>(type);
  event.modifiers = modifiers;
  event.native_key_code = native_key_code;
  event.character = character;
  event.unmodified_character = unmodified_character;
  host->SendKeyEvent(event);
}

void cmux_shim_osr_ime_set_composition(int browser_id, const char* text, int replace_from, int replace_to,
                                       int selection_from, int selection_to) {
  CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id);
  if (!host) return;
  const CefString value(text ? text : "");
  // One thin underline under the whole composition, as AppKit's default.
  std::vector<CefCompositionUnderline> underlines;
  cef_composition_underline_t line = {sizeof(cef_composition_underline_t),
                                      {0, static_cast<uint32_t>(value.length())},
                                      0xFF000000,
                                      0,
                                      0,
                                      CEF_CUS_SOLID};
  underlines.push_back(line);
  host->ImeSetComposition(value, underlines, RangeOf(replace_from, replace_to), RangeOf(selection_from, selection_to));
}

void cmux_shim_osr_ime_commit(int browser_id, const char* text, int replace_from, int replace_to,
                              int relative_cursor) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) {
    host->ImeCommitText(CefString(text ? text : ""), RangeOf(replace_from, replace_to), relative_cursor);
  }
}

void cmux_shim_osr_ime_finish(int browser_id, int keep_selection) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->ImeFinishComposingText(keep_selection != 0);
}

void cmux_shim_osr_ime_cancel(int browser_id) {
  if (CefRefPtr<CefBrowserHost> host = OffscreenHost(browser_id)) host->ImeCancelComposition();
}

void cmux_shim_osr_edit(int browser_id, int command) {
  if (!IsOffscreenBrowser(browser_id)) return;
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  CefRefPtr<CefFrame> frame = browser ? browser->GetFocusedFrame() : nullptr;
  if (!frame) return;
  switch (command) {
    case 0: frame->Undo(); break;
    case 1: frame->Redo(); break;
    case 2: frame->Cut(); break;
    case 3: frame->Copy(); break;
    case 4: frame->Paste(); break;
    case 5: frame->Delete(); break;
    case 6: frame->SelectAll(); break;
    case 7: frame->PasteAndMatchStyle(); break;
    default: break;
  }
}

void cmux_shim_osr_counters(uint64_t* out, int capacity) {
  const uint64_t values[] = {g_counters.frames,       g_counters.letterboxed,   g_counters.blit_us,
                             g_counters.refreshes,    g_counters.popup_frames,  g_counters.blit_failures,
                             g_counters.surfaces_made, offscreen_browsers().size()};
  for (int i = 0; i < capacity && i < static_cast<int>(sizeof(values) / sizeof(values[0])); ++i) out[i] = values[i];
}

}  // extern "C"
