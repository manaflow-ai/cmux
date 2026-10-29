// Ring frames to Chromium (host_input.h). The events are what cefclient's
// off-screen view builds from an NSEvent (tests/cefclient/browser/browser_window_osr_mac.mm);
// wheel ticks do not come here: browser_host_main.mm's SendWheel sends them with their phases
// and its WHEEL_ACK bookkeeping. Keys go through
// cmux_shim::SendHostKeyEvent with the frame's input seq, so a chord the page leaves unhandled
// comes back as KEY_UNHANDLED with it (task 030); Edit menu commands go to the focused frame.
#import <AppKit/AppKit.h>

#include <algorithm>

#include "include/cef_browser.h"

#include "cmux_cef_shim.h"
#include "host_input.h"
#include "shim_internal.h"

namespace cmux_host {
namespace {

// NSEventModifierFlags and the pressed mouse buttons (bits 1 left, 2 right, 4 middle) as
// cef_event_flags_t.
uint32_t CefFlags(uint64_t modifiers, int32_t buttons) {
  uint32_t flags = 0;
  if (modifiers & NSEventModifierFlagCapsLock) flags |= EVENTFLAG_CAPS_LOCK_ON;
  if (modifiers & NSEventModifierFlagShift) flags |= EVENTFLAG_SHIFT_DOWN;
  if (modifiers & NSEventModifierFlagControl) flags |= EVENTFLAG_CONTROL_DOWN;
  if (modifiers & NSEventModifierFlagOption) flags |= EVENTFLAG_ALT_DOWN;
  if (modifiers & NSEventModifierFlagCommand) flags |= EVENTFLAG_COMMAND_DOWN;
  if (modifiers & NSEventModifierFlagNumericPad) flags |= EVENTFLAG_IS_KEY_PAD;
  if (buttons & 1) flags |= EVENTFLAG_LEFT_MOUSE_BUTTON;
  if (buttons & 2) flags |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
  if (buttons & 4) flags |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
  return flags;
}

// The modifier a flags-changed key code belongs to.
uint64_t ModifierOfKey(int32_t key_code) {
  switch (key_code) {
    case 56: case 60: return NSEventModifierFlagShift;
    case 59: case 62: return NSEventModifierFlagControl;
    case 58: case 61: return NSEventModifierFlagOption;
    case 55: case 54: return NSEventModifierFlagCommand;
    case 57: return NSEventModifierFlagCapsLock;
    default: return 0;
  }
}

// VKEY_PROCESSKEY (ui/events/keycodes/keyboard_codes_posix.h): the key an input method took.
constexpr int kProcessKey = 0xE5;

// kKey: v0 phase (0 down, 1 up, 2 flags changed), v1 key code, v2 repeat, flags, ch, unmod, v3 the
// text input's mark (chromium_host_wire.h: 0 the key and its char, 1 an input method took it, 2 the
// char only), as RenderWidgetHostViewCocoa sends a key an input method handled
// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm, -keyEvent:wasKeyEquivalent:).
void SendKey(int chromium_browser_id, const Header& frame) {
  CefKeyEvent event;
  event.native_key_code = frame.v[1];
  event.modifiers = CefFlags(frame.flags, 0);
  if (frame.v[2]) event.modifiers |= EVENTFLAG_IS_REPEAT;
  if (frame.v[0] == 2) {
    // No characters: CEF builds a flags-changed event.
    event.type = (frame.flags & ModifierOfKey(frame.v[1])) ? KEYEVENT_RAWKEYDOWN : KEYEVENT_KEYUP;
    cmux_shim::SendHostKeyEvent(chromium_browser_id, 0, event);
    return;
  }
  const int32_t mark = frame.v[3];
  if (mark == 1) {
    // An input method took the key: VKEY_PROCESSKEY down or up, no character.
    event.windows_key_code = kProcessKey;
    event.type = frame.v[0] == 1 ? KEYEVENT_KEYUP : KEYEVENT_RAWKEYDOWN;
    cmux_shim::SendHostKeyEvent(chromium_browser_id, 0, event);
    return;
  }
  event.character = frame.ch;
  event.unmodified_character = frame.unmod;
  if (mark == 2) {
    // The character only, after the input method's turn.
    if (frame.v[0] != 0 || frame.ch == 0) return;
    event.type = KEYEVENT_CHAR;
    cmux_shim::SendHostKeyEvent(chromium_browser_id, 0, event);
    return;
  }
  event.type = frame.v[0] == 1 ? KEYEVENT_KEYUP : KEYEVENT_RAWKEYDOWN;
  cmux_shim::SendHostKeyEvent(chromium_browser_id, frame.seq, event);
  if (frame.v[0] == 1) return;
  // Text: a character that is not a function key (U+F700..U+F8FF), with no Command chord.
  const bool function_key = frame.ch >= 0xF700 && frame.ch <= 0xF8FF;
  if (frame.ch != 0 && !function_key && !(frame.flags & NSEventModifierFlagCommand)) {
    event.type = KEYEVENT_CHAR;
    cmux_shim::SendHostKeyEvent(chromium_browser_id, 0, event);
  }
}

// kEdit: v0 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo, to the page's focused frame.
void SendEdit(CefRefPtr<CefBrowser> browser, const Header& frame) {
  CefRefPtr<CefFrame> focused = browser->GetFocusedFrame();
  if (!focused) return;
  switch (frame.v[0]) {
    case 0: focused->Copy(); break;
    case 1: focused->Cut(); break;
    case 2: focused->Paste(); break;
    case 3: focused->SelectAll(); break;
    case 4: focused->Undo(); break;
    case 5: focused->Redo(); break;
    default: break;
  }
}

// kMouse: v0 x, v1 y, v2 phase (0 move, 1 down, 2 up, 3 exit), v3 button (0 left, 1 middle,
// 2 right), v4 click count, v5 pressed buttons, flags.
void SendMouse(CefRefPtr<CefBrowserHost> host, const Header& frame) {
  CefMouseEvent mouse;
  mouse.x = frame.v[0];
  mouse.y = frame.v[1];
  mouse.modifiers = CefFlags(frame.flags, frame.v[5]);
  const int32_t phase = frame.v[2];
  if (phase == 0 || phase == 3) {
    host->SendMouseMoveEvent(mouse, phase == 3);
    return;
  }
  const cef_mouse_button_type_t button = frame.v[3] == 2 ? MBT_RIGHT : frame.v[3] == 1 ? MBT_MIDDLE : MBT_LEFT;
  host->SendMouseClickEvent(mouse, button, phase == 2, std::max(1, frame.v[4]));
}

}  // namespace

void DispatchInputFrame(int chromium_browser_id, const Header& frame) {
  CefRefPtr<CefBrowser> browser = cmux_shim::BrowserById(chromium_browser_id);
  if (!browser) return;
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host) return;
  switch (frame.kind) {
    case kKey:
      SendKey(chromium_browser_id, frame);
      break;
    case kMouse:
      SendMouse(host, frame);
      break;
    case kEdit:
      SendEdit(browser, frame);
      break;
    default:
      break;
  }
}

}  // namespace cmux_host
