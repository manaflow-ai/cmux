// CEF C-API bridge. See cmux_cef_shim.h for the contract.
//
// Handler structs are embedded in one heap-allocated wrapper per browser and
// share the wrapper's reference count, so any handler reference CEF retains
// keeps the whole wrapper alive. The wrapper is freed only when CEF has
// released every handler and the Swift owner has called release.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/views/cef_fill_layout_capi.h"
#include "include/capi/views/cef_browser_view_capi.h"
#include "include/capi/views/cef_browser_view_delegate_capi.h"
#include "include/capi/views/cef_window_capi.h"
#include "include/capi/views/cef_window_delegate_capi.h"

#include "cmux_cef_shim.h"

// MARK: - Globals

static int g_initialized = 0;
static int g_initialize_attempted = 0;
static int g_remote_debugging_port = 0;
static void (*g_schedule_work)(int64_t delay_ms) = NULL;

// The cef_app_t and its process handler live for the process lifetime.
static cef_app_t g_app;
static cef_browser_process_handler_t g_browser_process_handler;

// CEF request contexts are process-local. Keep one context per logical named
// profile so multiple CEF panes share cookies/storage without opening the same
// on-disk cache through competing context instances.
struct cmux_cef_profile_context {
  char *cache_path;
  cef_request_context_t *context;
  size_t users;
  struct cmux_cef_profile_context *next;
};

static struct cmux_cef_profile_context *g_profile_contexts = NULL;

// MARK: - Static ref-count no-ops for process-lifetime structs

static void CEF_CALLBACK static_add_ref(cef_base_ref_counted_t *self) {}
static int CEF_CALLBACK static_release(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK static_has_one_ref(cef_base_ref_counted_t *self) { return 1; }
static int CEF_CALLBACK static_has_any_ref(cef_base_ref_counted_t *self) { return 1; }

static void init_static_base(cef_base_ref_counted_t *base, size_t size) {
  base->size = size;
  base->add_ref = static_add_ref;
  base->release = static_release;
  base->has_one_ref = static_has_one_ref;
  base->has_at_least_one_ref = static_has_any_ref;
}

// MARK: - String helpers

static void set_cef_string(cef_string_t *target, const char *utf8) {
  if (utf8) {
    cef_string_utf8_to_utf16(utf8, strlen(utf8), target);
  }
}

/// Returns a malloc'd UTF-8 copy of a CEF string; caller frees.
static char *copy_utf8(const cef_string_t *value) {
  if (!value || !value->str) return strdup("");
  cef_string_utf8_t utf8 = {};
  cef_string_utf16_to_utf8(value->str, value->length, &utf8);
  char *result = strndup(utf8.str ? utf8.str : "", utf8.length);
  cef_string_utf8_clear(&utf8);
  return result;
}

// MARK: - Browser wrapper

struct cmux_cef_browser {
  // Handlers CEF holds references to. Each shares the wrapper ref count.
  cef_client_t client;
  cef_life_span_handler_t life_span;
  cef_display_handler_t display;
  cef_load_handler_t load;
  cef_request_handler_t request;
  cef_dev_tools_message_observer_t devtools;
  cef_window_delegate_t window_delegate;
  cef_browser_view_delegate_t view_delegate;

  atomic_int refs;
  cmux_cef_browser_callbacks_t callbacks;
  char *initial_url;
  cef_request_context_t *request_context;
  struct cmux_cef_profile_context *profile_context;

  cef_browser_t *browser;
  cef_window_t *window;
  cef_registration_t *devtools_registration;
  int closed;
};

static void browser_retain(struct cmux_cef_browser *wrapper) {
  atomic_fetch_add_explicit(&wrapper->refs, 1, memory_order_relaxed);
}

static int browser_release_ref(struct cmux_cef_browser *wrapper) {
  if (atomic_fetch_sub_explicit(&wrapper->refs, 1, memory_order_acq_rel) == 1) {
    free(wrapper->initial_url);
    free(wrapper);
    return 1;
  }
  return 0;
}

static struct cmux_cef_profile_context *profile_context_acquire(
    const char *cache_path, cef_request_context_t **context_out) {
  if (!cache_path || !cache_path[0] || !context_out) return NULL;
  for (struct cmux_cef_profile_context *entry = g_profile_contexts;
       entry; entry = entry->next) {
    if (strcmp(entry->cache_path, cache_path) == 0) {
      entry->users += 1;
      ((cef_base_ref_counted_t *)entry->context)
          ->add_ref((cef_base_ref_counted_t *)entry->context);
      *context_out = entry->context;
      return entry;
    }
  }

  cef_request_context_settings_t settings;
  memset(&settings, 0, sizeof(settings));
  settings.size = sizeof(settings);
  set_cef_string(&settings.cache_path, cache_path);
  cef_request_context_t *context =
      cef_request_context_create_context(&settings, NULL);
  cef_string_clear(&settings.cache_path);
  if (!context) return NULL;

  struct cmux_cef_profile_context *entry =
      calloc(1, sizeof(*entry));
  if (!entry) {
    ((cef_base_ref_counted_t *)context)
        ->release((cef_base_ref_counted_t *)context);
    return NULL;
  }
  entry->cache_path = strdup(cache_path);
  if (!entry->cache_path) {
    free(entry);
    ((cef_base_ref_counted_t *)context)
        ->release((cef_base_ref_counted_t *)context);
    return NULL;
  }
  entry->context = context;  // Registry-owned +1 from create_context.
  entry->users = 1;
  entry->next = g_profile_contexts;
  g_profile_contexts = entry;
  ((cef_base_ref_counted_t *)context)
      ->add_ref((cef_base_ref_counted_t *)context);  // Wrapper-owned +1.
  *context_out = context;
  return entry;
}

static void profile_context_release(
    struct cmux_cef_profile_context *entry) {
  if (!entry || entry->users == 0) return;
  entry->users -= 1;
  if (entry->users != 0) return;

  struct cmux_cef_profile_context **cursor = &g_profile_contexts;
  while (*cursor && *cursor != entry) cursor = &(*cursor)->next;
  if (*cursor == entry) *cursor = entry->next;
  ((cef_base_ref_counted_t *)entry->context)
      ->release((cef_base_ref_counted_t *)entry->context);
  free(entry->cache_path);
  free(entry);
}

// Generates base callbacks that forward to the wrapper's shared ref count.
#define DEFINE_HANDLER_BASE(field)                                             \
  static struct cmux_cef_browser *field##_wrapper(void *self) {                \
    return (struct cmux_cef_browser *)((char *)self -                          \
                                       offsetof(struct cmux_cef_browser,       \
                                                field));                       \
  }                                                                            \
  static void CEF_CALLBACK field##_add_ref(cef_base_ref_counted_t *self) {     \
    browser_retain(field##_wrapper(self));                                     \
  }                                                                            \
  static int CEF_CALLBACK field##_release(cef_base_ref_counted_t *self) {      \
    return browser_release_ref(field##_wrapper(self));                         \
  }                                                                            \
  static int CEF_CALLBACK field##_has_one_ref(cef_base_ref_counted_t *self) {  \
    return atomic_load(&field##_wrapper(self)->refs) == 1;                     \
  }                                                                            \
  static int CEF_CALLBACK field##_has_any_ref(cef_base_ref_counted_t *self) {  \
    return atomic_load(&field##_wrapper(self)->refs) >= 1;                     \
  }                                                                            \
  static void field##_init_base(struct cmux_cef_browser *wrapper,              \
                                cef_base_ref_counted_t *base, size_t size) {   \
    base->size = size;                                                         \
    base->add_ref = field##_add_ref;                                           \
    base->release = field##_release;                                           \
    base->has_one_ref = field##_has_one_ref;                                   \
    base->has_at_least_one_ref = field##_has_any_ref;                          \
  }

DEFINE_HANDLER_BASE(client)
DEFINE_HANDLER_BASE(life_span)
DEFINE_HANDLER_BASE(display)
DEFINE_HANDLER_BASE(load)
DEFINE_HANDLER_BASE(request)
DEFINE_HANDLER_BASE(devtools)
DEFINE_HANDLER_BASE(window_delegate)
DEFINE_HANDLER_BASE(view_delegate)

// MARK: - Client handler getters (returned +1 per CEF C-API convention)

static cef_life_span_handler_t *CEF_CALLBACK client_get_life_span_handler(
    cef_client_t *self) {
  struct cmux_cef_browser *wrapper = client_wrapper(self);
  browser_retain(wrapper);
  return &wrapper->life_span;
}

static cef_display_handler_t *CEF_CALLBACK client_get_display_handler(
    cef_client_t *self) {
  struct cmux_cef_browser *wrapper = client_wrapper(self);
  browser_retain(wrapper);
  return &wrapper->display;
}

static cef_load_handler_t *CEF_CALLBACK client_get_load_handler(
    cef_client_t *self) {
  struct cmux_cef_browser *wrapper = client_wrapper(self);
  browser_retain(wrapper);
  return &wrapper->load;
}

static cef_request_handler_t *CEF_CALLBACK client_get_request_handler(
    cef_client_t *self) {
  struct cmux_cef_browser *wrapper = client_wrapper(self);
  browser_retain(wrapper);
  return &wrapper->request;
}

// MARK: - Life span

static void CEF_CALLBACK life_span_on_after_created(
    cef_life_span_handler_t *self, cef_browser_t *browser) {
  struct cmux_cef_browser *wrapper = life_span_wrapper(self);
  if (wrapper->browser) return;  // DevTools popups reuse the same client.
  ((cef_base_ref_counted_t *)browser)->add_ref((cef_base_ref_counted_t *)browser);
  wrapper->browser = browser;
  cef_browser_host_t *host = browser->get_host(browser);
  if (host) {
    wrapper->devtools_registration =
        host->add_dev_tools_message_observer(host, &wrapper->devtools);
    ((cef_base_ref_counted_t *)host)->release((cef_base_ref_counted_t *)host);
  }
  if (wrapper->callbacks.on_created) {
    void *ns_window = NULL;
    if (wrapper->window) {
      void *root_view = wrapper->window->get_window_handle(wrapper->window);
      if (root_view) {
        ns_window = (__bridge void *)[(__bridge NSView *)root_view window];
      }
    }
    wrapper->callbacks.on_created(wrapper->callbacks.context, ns_window);
  }
}

static void CEF_CALLBACK life_span_on_before_close(
    cef_life_span_handler_t *self, cef_browser_t *browser) {
  struct cmux_cef_browser *wrapper = life_span_wrapper(self);
  if (wrapper->browser != browser) return;
  wrapper->closed = 1;
  if (wrapper->devtools_registration) {
    cef_registration_t *registration = wrapper->devtools_registration;
    wrapper->devtools_registration = NULL;
    ((cef_base_ref_counted_t *)registration)
        ->release((cef_base_ref_counted_t *)registration);
  }
  if (wrapper->browser) {
    ((cef_base_ref_counted_t *)wrapper->browser)
        ->release((cef_base_ref_counted_t *)wrapper->browser);
    wrapper->browser = NULL;
  }
  if (wrapper->window) {
    ((cef_base_ref_counted_t *)wrapper->window)
        ->release((cef_base_ref_counted_t *)wrapper->window);
    wrapper->window = NULL;
  }
  if (wrapper->request_context) {
    ((cef_base_ref_counted_t *)wrapper->request_context)
        ->release((cef_base_ref_counted_t *)wrapper->request_context);
    wrapper->request_context = NULL;
  }
  profile_context_release(wrapper->profile_context);
  wrapper->profile_context = NULL;
  if (wrapper->callbacks.on_closed) {
    wrapper->callbacks.on_closed(wrapper->callbacks.context);
  }
}

// MARK: - Display / load state

static void CEF_CALLBACK display_on_title_change(cef_display_handler_t *self,
                                                 cef_browser_t *browser,
                                                 const cef_string_t *title) {
  struct cmux_cef_browser *wrapper = display_wrapper(self);
  if (wrapper->browser != browser || !wrapper->callbacks.on_title_changed) return;
  char *utf8 = copy_utf8(title);
  wrapper->callbacks.on_title_changed(wrapper->callbacks.context, utf8);
  free(utf8);
}

static void CEF_CALLBACK display_on_address_change(cef_display_handler_t *self,
                                                   cef_browser_t *browser,
                                                   struct _cef_frame_t *frame,
                                                   const cef_string_t *url) {
  struct cmux_cef_browser *wrapper = display_wrapper(self);
  if (wrapper->browser != browser || !wrapper->callbacks.on_address_changed) return;
  if (frame && !frame->is_main(frame)) return;
  char *utf8 = copy_utf8(url);
  wrapper->callbacks.on_address_changed(wrapper->callbacks.context, utf8);
  free(utf8);
}

static void CEF_CALLBACK load_on_loading_state_change(cef_load_handler_t *self,
                                                      cef_browser_t *browser,
                                                      int isLoading,
                                                      int canGoBack,
                                                      int canGoForward) {
  struct cmux_cef_browser *wrapper = load_wrapper(self);
  if (wrapper->browser != browser || !wrapper->callbacks.on_loading_state_changed) {
    return;
  }
  wrapper->callbacks.on_loading_state_changed(wrapper->callbacks.context,
                                              isLoading, canGoBack, canGoForward);
}

static void CEF_CALLBACK request_on_render_process_terminated(
    cef_request_handler_t *self, cef_browser_t *browser,
    cef_termination_status_t status, int error_code,
    const cef_string_t *error_string) {
  struct cmux_cef_browser *wrapper = request_wrapper(self);
  if (wrapper->browser != browser || !wrapper->callbacks.on_renderer_crashed) {
    return;
  }
  wrapper->callbacks.on_renderer_crashed(wrapper->callbacks.context);
}

static int CEF_CALLBACK request_on_before_browse(
    cef_request_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
    cef_request_t *request, int user_gesture, int is_redirect) {
  struct cmux_cef_browser *wrapper = request_wrapper(self);
  if (wrapper->browser != browser || !frame || !frame->is_main(frame) ||
      !request || !request->get_url ||
      !wrapper->callbacks.should_block_navigation) {
    return 0;
  }
  cef_string_userfree_t url = request->get_url(request);
  char *utf8 = copy_utf8(url);
  cef_string_userfree_free(url);
  int blocked = wrapper->callbacks.should_block_navigation(
      wrapper->callbacks.context, utf8);
  free(utf8);
  return blocked ? 1 : 0;
}

// MARK: - DevTools

static int CEF_CALLBACK devtools_on_message(
    cef_dev_tools_message_observer_t *self, cef_browser_t *browser,
    const void *message, size_t message_size) {
  struct cmux_cef_browser *wrapper = devtools_wrapper(self);
  if (wrapper->callbacks.on_dev_tools_message) {
    wrapper->callbacks.on_dev_tools_message(wrapper->callbacks.context, message,
                                            message_size);
  }
  // Handled: suppress the redundant method-result/event callbacks.
  return 1;
}

// MARK: - Views delegates

static cef_chrome_toolbar_type_t CEF_CALLBACK view_delegate_toolbar_type(
    cef_browser_view_delegate_t *self, cef_browser_view_t *browser_view) {
  return CEF_CTT_NONE;
}

static int CEF_CALLBACK window_delegate_is_frameless(cef_window_delegate_t *self,
                                                     cef_window_t *window) {
  return 1;
}

static int CEF_CALLBACK window_delegate_standard_buttons(
    cef_window_delegate_t *self, cef_window_t *window) {
  return 0;
}

static cef_rect_t CEF_CALLBACK window_delegate_initial_bounds(
    cef_window_delegate_t *self, cef_window_t *window) {
  cef_rect_t bounds = {0, 0, 1024, 700};
  return bounds;
}

static void CEF_CALLBACK window_delegate_on_window_created(
    cef_window_delegate_t *self, cef_window_t *window) {
  struct cmux_cef_browser *wrapper = window_delegate_wrapper(self);
  ((cef_base_ref_counted_t *)window)->add_ref((cef_base_ref_counted_t *)window);
  wrapper->window = window;

  cef_string_t url = {};
  set_cef_string(&url, wrapper->initial_url ?: "about:blank");
  cef_browser_settings_t browser_settings;
  memset(&browser_settings, 0, sizeof(browser_settings));
  browser_settings.size = sizeof(browser_settings);
  cef_browser_view_t *view = cef_browser_view_create(
      &wrapper->client, &url, &browser_settings, NULL, wrapper->request_context,
      &wrapper->view_delegate);
  cef_string_clear(&url);
  if (!view) return;
  cef_panel_t *panel = (cef_panel_t *)window;
  panel->add_child_view(panel, (cef_view_t *)view);
  // add_child_view retains the view; release the factory's caller-owned
  // reference once the window has adopted it.
  ((cef_base_ref_counted_t *)view)->release((cef_base_ref_counted_t *)view);
  cef_fill_layout_t *fill_layout = panel->set_to_fill_layout(panel);
  if (fill_layout) {
    ((cef_base_ref_counted_t *)fill_layout)
        ->release((cef_base_ref_counted_t *)fill_layout);
  }
  panel->layout(panel);
  // Deliberately not shown here: the window would appear at its initial
  // bounds before the pane adopts it. CEFBrowserHostView orders it in once
  // it is positioned over the pane rect.
}

// Comma-joined unpacked extension directories captured at initialize.
static char *g_extension_paths = NULL;

// MARK: - Process-level handlers

// On macOS Chromium reads the real process command line and ignores
// cef_main_args, so programmatic switches must be appended here.
static void append_switch(struct _cef_command_line_t *command_line,
                          const char *switch_name) {
  cef_string_t name = {};
  set_cef_string(&name, switch_name);
  command_line->append_switch(command_line, &name);
  cef_string_clear(&name);
}

static void append_switch_with_value(struct _cef_command_line_t *command_line,
                                     const char *switch_name,
                                     const char *value_string) {
  cef_string_t name = {};
  cef_string_t value = {};
  set_cef_string(&name, switch_name);
  set_cef_string(&value, value_string);
  command_line->append_switch_with_value(command_line, &name, &value);
  cef_string_clear(&name);
  cef_string_clear(&value);
}

static void CEF_CALLBACK app_on_before_command_line_processing(
    cef_app_t *self, const cef_string_t *process_type,
    struct _cef_command_line_t *command_line) {
  if (process_type && process_type->length > 0) return;  // Browser process only.
  // Debug-tagged bundles may use a mock keychain to avoid prompting during
  // local dogfood. Release builds retain Chromium's real Keychain-backed
  // Safe Storage encryption for persisted cookies and session tokens.
#if DEBUG
  append_switch(command_line, "use-mock-keychain");
#endif
  if (g_extension_paths && g_extension_paths[0]) {
    append_switch_with_value(command_line, "load-extension", g_extension_paths);
    append_switch_with_value(command_line, "disable-extensions-except", g_extension_paths);
  }
  if (g_remote_debugging_port > 0) {
    char origins[256];
    snprintf(
        origins, sizeof(origins),
        "http://127.0.0.1:%d,http://localhost:%d,devtools://devtools",
        g_remote_debugging_port, g_remote_debugging_port);
    append_switch_with_value(command_line, "remote-allow-origins", origins);
  }
}

static void CEF_CALLBACK on_schedule_message_pump_work(
    cef_browser_process_handler_t *self, int64_t delay_ms) {
  void (*schedule)(int64_t) = g_schedule_work;
  if (schedule) schedule(delay_ms);
}

static cef_browser_process_handler_t *CEF_CALLBACK app_get_browser_process_handler(
    cef_app_t *self) {
  return &g_browser_process_handler;
}

// MARK: - NSApplication conformance injection

// CEF requires [NSApp isHandlingSendEvent]. cmux's NSApplication instance
// already exists when CEF initializes lazily, so the methods are added to its
// class at runtime and sendEvent: is wrapped to maintain the flag.
static const void *kHandlingSendEventKey = &kHandlingSendEventKey;
static IMP g_original_send_event = NULL;

static BOOL shim_is_handling_send_event(id self, SEL _cmd) {
  return [objc_getAssociatedObject(self, kHandlingSendEventKey) boolValue];
}

static void shim_set_handling_send_event(id self, SEL _cmd, BOOL handling) {
  objc_setAssociatedObject(self, kHandlingSendEventKey, @(handling),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void shim_send_event(id self, SEL _cmd, NSEvent *event) {
  BOOL previous = shim_is_handling_send_event(self, _cmd);
  shim_set_handling_send_event(self, _cmd, YES);
  ((void (*)(id, SEL, NSEvent *))g_original_send_event)(self, _cmd, event);
  shim_set_handling_send_event(self, _cmd, previous);
}

static void install_application_conformance(void) {
  Class applicationClass = object_getClass(NSApp) ? [NSApp class] : [NSApplication class];
  if (!class_getInstanceMethod(applicationClass, @selector(isHandlingSendEvent))) {
    class_addMethod(applicationClass, @selector(isHandlingSendEvent),
                    (IMP)shim_is_handling_send_event, "c@:");
    class_addMethod(applicationClass, @selector(setHandlingSendEvent:),
                    (IMP)shim_set_handling_send_event, "v@:c");
    Method sendEvent = class_getInstanceMethod(applicationClass, @selector(sendEvent:));
    g_original_send_event = method_getImplementation(sendEvent);
    method_setImplementation(sendEvent, (IMP)shim_send_event);
  }
}

// MARK: - Public API

static NSString *frameworks_directory(const char *framework_directory) {
  if (framework_directory) {
    return [NSString stringWithUTF8String:framework_directory];
  }
  return NSBundle.mainBundle.privateFrameworksPath;
}

static int g_framework_loaded = 0;

static int load_framework(const char *framework_directory) {
  if (g_framework_loaded) return 1;
  NSString *directory = frameworks_directory(framework_directory);
  NSString *path = [directory stringByAppendingPathComponent:
      @"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
  void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!handle) {
    NSLog(@"cmux_cef: dlopen failed: %s", dlerror());
    return 0;
  }
  cef_api_hash(CEF_API_VERSION, 0);
  g_framework_loaded = 1;
  return 1;
}

int cmux_cef_preload_framework(const char *framework_directory) {
  return load_framework(framework_directory);
}

int cmux_cef_initialize(const cmux_cef_init_options_t *options) {
  if (g_initialize_attempted) return g_initialized;
  g_initialize_attempted = 1;
  if (!options || !options->root_cache_path) return 0;
  if (!load_framework(options->framework_directory)) return 0;

  install_application_conformance();

  // Synthetic command line: cmux's own argv is irrelevant to CEF, and the
  // extension switches must be present at browser-process startup.
  NSMutableArray<NSString *> *arguments = [NSMutableArray array];
  [arguments addObject:NSProcessInfo.processInfo.arguments.firstObject ?: @"cmux"];
  if (options->extension_directories && options->extension_directories[0]) {
    NSArray<NSString *> *lines = [[NSString
        stringWithUTF8String:options->extension_directories]
        componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *paths = [lines
        filteredArrayUsingPredicate:[NSPredicate
                                        predicateWithBlock:^BOOL(NSString *line,
                                                                 NSDictionary *bindings) {
                                          return line.length > 0;
                                        }]];
    if (paths.count > 0) {
      NSString *joined = [paths componentsJoinedByString:@","];
      free(g_extension_paths);
      g_extension_paths = strdup(joined.UTF8String);
    }
  }
  int argc = (int)arguments.count;
  char **argv = calloc((size_t)argc + 1, sizeof(char *));
  for (int i = 0; i < argc; i++) {
    argv[i] = strdup(arguments[i].UTF8String);
  }
  cef_main_args_t main_args = {argc, argv};

  cef_settings_t settings;
  memset(&settings, 0, sizeof(settings));
  settings.size = sizeof(settings);
#if DEBUG
  // Tagged Debug bundles are ad-hoc signed and cannot launch the helper with
  // Chromium's production sandbox entitlement. Release builds leave this
  // disabled so CEF keeps its renderer sandbox boundary.
  settings.no_sandbox = 1;
#else
  settings.no_sandbox = 0;
#endif
  settings.external_message_pump = 1;
  settings.remote_debugging_port = options->remote_debugging_port;
  settings.log_severity = LOGSEVERITY_WARNING;
  set_cef_string(&settings.root_cache_path, options->root_cache_path);
  // Fixed helper names keep per-tag product names out of process discovery.
  NSString *helperPath = [frameworks_directory(options->framework_directory)
      stringByAppendingPathComponent:
          @"cmux CEF Helper.app/Contents/MacOS/cmux CEF Helper"];
  set_cef_string(&settings.browser_subprocess_path, helperPath.UTF8String);
  if (options->log_file_path) {
    set_cef_string(&settings.log_file, options->log_file_path);
  }

  memset(&g_browser_process_handler, 0, sizeof(g_browser_process_handler));
  init_static_base(&g_browser_process_handler.base, sizeof(g_browser_process_handler));
  g_browser_process_handler.on_schedule_message_pump_work =
      on_schedule_message_pump_work;

  memset(&g_app, 0, sizeof(g_app));
  init_static_base(&g_app.base, sizeof(g_app));
  g_app.get_browser_process_handler = app_get_browser_process_handler;
  g_app.on_before_command_line_processing = app_on_before_command_line_processing;

  // Publish the requested port before CEF invokes the command-line callback;
  // the callback must allow-list the exact loopback origins for this listener.
  g_remote_debugging_port = options->remote_debugging_port;
  g_initialized = cef_initialize(&main_args, &settings, &g_app, NULL) ? 1 : 0;
  if (!g_initialized) g_remote_debugging_port = 0;
  return g_initialized;
}

int cmux_cef_is_initialized(void) {
  return g_initialized;
}

int cmux_cef_remote_debugging_port(void) {
  return g_remote_debugging_port;
}

void cmux_cef_set_schedule_work_callback(void (*schedule)(int64_t delay_ms)) {
  g_schedule_work = schedule;
}

void cmux_cef_do_work(void) {
  if (g_initialized) cef_do_message_loop_work();
}

cmux_cef_browser_t *cmux_cef_browser_create(
    const char *url, const char *cache_path,
    const cmux_cef_browser_callbacks_t *callbacks) {
  if (!g_initialized || !callbacks) return NULL;
  struct cmux_cef_browser *wrapper = calloc(1, sizeof(*wrapper));
  atomic_init(&wrapper->refs, 1);  // Caller's reference.
  wrapper->callbacks = *callbacks;
  wrapper->initial_url = strdup(url ?: "about:blank");

  client_init_base(wrapper, &wrapper->client.base, sizeof(wrapper->client));
  wrapper->client.get_life_span_handler = client_get_life_span_handler;
  wrapper->client.get_display_handler = client_get_display_handler;
  wrapper->client.get_load_handler = client_get_load_handler;
  wrapper->client.get_request_handler = client_get_request_handler;

  life_span_init_base(wrapper, &wrapper->life_span.base, sizeof(wrapper->life_span));
  wrapper->life_span.on_after_created = life_span_on_after_created;
  wrapper->life_span.on_before_close = life_span_on_before_close;

  display_init_base(wrapper, &wrapper->display.base, sizeof(wrapper->display));
  wrapper->display.on_title_change = display_on_title_change;
  wrapper->display.on_address_change = display_on_address_change;

  load_init_base(wrapper, &wrapper->load.base, sizeof(wrapper->load));
  wrapper->load.on_loading_state_change = load_on_loading_state_change;

  request_init_base(wrapper, &wrapper->request.base, sizeof(wrapper->request));
  wrapper->request.on_before_browse = request_on_before_browse;
  wrapper->request.on_render_process_terminated =
      request_on_render_process_terminated;

  devtools_init_base(wrapper, &wrapper->devtools.base, sizeof(wrapper->devtools));
  wrapper->devtools.on_dev_tools_message = devtools_on_message;

  view_delegate_init_base(wrapper, &wrapper->view_delegate.base.base,
                          sizeof(wrapper->view_delegate));
  wrapper->view_delegate.get_chrome_toolbar_type = view_delegate_toolbar_type;

  window_delegate_init_base(wrapper, &wrapper->window_delegate.base.base.base,
                            sizeof(wrapper->window_delegate));
  wrapper->window_delegate.on_window_created = window_delegate_on_window_created;
  wrapper->window_delegate.is_frameless = window_delegate_is_frameless;
  wrapper->window_delegate.with_standard_window_buttons =
      window_delegate_standard_buttons;
  wrapper->window_delegate.get_initial_bounds = window_delegate_initial_bounds;

  if (cache_path && cache_path[0]) {
    wrapper->profile_context = profile_context_acquire(
        cache_path, &wrapper->request_context);
    if (!wrapper->profile_context || !wrapper->request_context) {
      profile_context_release(wrapper->profile_context);
      wrapper->profile_context = NULL;
      browser_release_ref(wrapper);
      return NULL;
    }
  }

  cef_window_t *created_window =
      cef_window_create_top_level(&wrapper->window_delegate);
  if (!created_window) {
    if (wrapper->request_context) {
      ((cef_base_ref_counted_t *)wrapper->request_context)
          ->release((cef_base_ref_counted_t *)wrapper->request_context);
      wrapper->request_context = NULL;
    }
    profile_context_release(wrapper->profile_context);
    wrapper->profile_context = NULL;
    browser_release_ref(wrapper);
    return NULL;
  }
  // The window delegate retains the adopted window; balance the factory's
  // caller-owned reference returned from create_top_level.
  ((cef_base_ref_counted_t *)created_window)
      ->release((cef_base_ref_counted_t *)created_window);
  return wrapper;
}

void cmux_cef_browser_close(cmux_cef_browser_t *browser) {
  if (!browser || browser->closed) return;
  if (browser->window) {
    browser->window->close(browser->window);
  }
}

void cmux_cef_browser_release(cmux_cef_browser_t *browser) {
  if (browser) browser_release_ref(browser);
}

void cmux_cef_browser_load_url(cmux_cef_browser_t *browser, const char *url) {
  if (!browser || !browser->browser || !url) return;
  cef_frame_t *frame = browser->browser->get_main_frame(browser->browser);
  if (!frame) return;
  cef_string_t target = {};
  set_cef_string(&target, url);
  frame->load_url(frame, &target);
  cef_string_clear(&target);
  ((cef_base_ref_counted_t *)frame)->release((cef_base_ref_counted_t *)frame);
}

void cmux_cef_browser_go_back(cmux_cef_browser_t *browser) {
  if (browser && browser->browser) browser->browser->go_back(browser->browser);
}

void cmux_cef_browser_go_forward(cmux_cef_browser_t *browser) {
  if (browser && browser->browser) browser->browser->go_forward(browser->browser);
}

void cmux_cef_browser_reload(cmux_cef_browser_t *browser) {
  if (browser && browser->browser) browser->browser->reload(browser->browser);
}

void cmux_cef_browser_stop(cmux_cef_browser_t *browser) {
  if (browser && browser->browser) browser->browser->stop_load(browser->browser);
}

int cmux_cef_browser_send_dev_tools_message(cmux_cef_browser_t *browser,
                                            const void *json, size_t length) {
  if (!browser || !browser->browser || !json || length == 0) return 0;
  cef_browser_host_t *host = browser->browser->get_host(browser->browser);
  if (!host) return 0;
  int result = host->send_dev_tools_message(host, json, length);
  ((cef_base_ref_counted_t *)host)->release((cef_base_ref_counted_t *)host);
  return result;
}
