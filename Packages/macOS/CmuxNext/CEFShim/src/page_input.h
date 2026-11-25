// Forwarded page input: one translation of cmux's page view events (ChromiumPageInput in
// Sources/CmuxNextBrowser/CEF/ChromiumPageInput.swift) into CefBrowserHost calls, shared by the
// two places that forward it: presented pages in cmux's own process (shim_presented.mm) and the
// helper app's browser process (browser_host_main.mm, over the wire). Header only. UI thread.
#pragma once

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cstdint>

#include "include/cef_browser.h"

namespace cmux_page_input {

// NSEventModifierFlags (and the pressed mouse buttons: 1 left, 2 right, 4 middle, NSEvent's order)
// as cef_event_flags_t.
inline uint32_t CefFlags(uint64_t ns, int buttons) {
  uint32_t flags = 0;
  if (ns & NSEventModifierFlagCapsLock) flags |= EVENTFLAG_CAPS_LOCK_ON;
  if (ns & NSEventModifierFlagShift) flags |= EVENTFLAG_SHIFT_DOWN;
  if (ns & NSEventModifierFlagControl) flags |= EVENTFLAG_CONTROL_DOWN;
  if (ns & NSEventModifierFlagOption) flags |= EVENTFLAG_ALT_DOWN;
  if (ns & NSEventModifierFlagCommand) flags |= EVENTFLAG_COMMAND_DOWN;
  if (ns & NSEventModifierFlagNumericPad) flags |= EVENTFLAG_IS_KEY_PAD;
  if (buttons & 1) flags |= EVENTFLAG_LEFT_MOUSE_BUTTON;
  if (buttons & 2) flags |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
  if (buttons & 4) flags |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
  return flags;
}

// The modifier key a flags-changed key code belongs to.
inline uint64_t ModifierOfKey(int key_code) {
  switch (key_code) {
    case 56: case 60: return NSEventModifierFlagShift;
    case 59: case 62: return NSEventModifierFlagControl;
    case 58: case 61: return NSEventModifierFlagOption;
    case 55: case 54: return NSEventModifierFlagCommand;
    case 57: return NSEventModifierFlagCapsLock;
    default: return 0;
  }
}

// A key: phase 0 down, 1 up, 2 flags changed; `ch` and `unmod` are the first UTF-16 unit of the
// event's characters and charactersIgnoringModifiers (0 for none). A key down is a raw key down and,
// for text (a character that is not a function key, U+F700..U+F8FF, and no Command chord), a char
// event, as cefclient's off-screen view sends it. CEF builds the NSEvent Chromium reads from these
// (its timestamp is the app's current event's, the key being forwarded).
inline void SendKey(CefRefPtr<CefBrowserHost> host, int phase, int key_code, uint16_t ch, uint16_t unmod,
                    uint64_t ns_flags, bool repeat) {
  CefKeyEvent event;
  event.native_key_code = key_code;
  event.modifiers = CefFlags(ns_flags, 0);
  if (repeat) event.modifiers |= EVENTFLAG_IS_REPEAT;
  if (phase == 2) {
    // Flags changed: no characters, so CEF builds a flags-changed event.
    event.type = (ns_flags & ModifierOfKey(key_code)) ? KEYEVENT_RAWKEYDOWN : KEYEVENT_KEYUP;
    host->SendKeyEvent(event);
    return;
  }
  event.character = ch;
  event.unmodified_character = unmod;
  if (phase == 1) {
    event.type = KEYEVENT_KEYUP;
    host->SendKeyEvent(event);
    return;
  }
  event.type = KEYEVENT_RAWKEYDOWN;
  host->SendKeyEvent(event);
  const bool function_key = ch >= 0xF700 && ch <= 0xF8FF;
  if (ch && !function_key && !(ns_flags & NSEventModifierFlagCommand)) {
    event.type = KEYEVENT_CHAR;
    host->SendKeyEvent(event);
  }
}

// A mouse event at (x, y), the page view's points from its top left: phase 0 move, 1 down, 2 up,
// 3 exit; button 0 left, 1 middle, 2 right; `buttons` the pressed buttons (1 left, 2 right, 4 middle).
inline void SendMouse(CefRefPtr<CefBrowserHost> host, int x, int y, int phase, int button, int click_count,
                      int buttons, uint64_t ns_flags) {
  CefMouseEvent mouse;
  mouse.x = x;
  mouse.y = y;
  mouse.modifiers = CefFlags(ns_flags, buttons);
  if (phase == 0 || phase == 3) {
    host->SendMouseMoveEvent(mouse, phase == 3);
    return;
  }
  const auto type = button == 2 ? MBT_RIGHT : button == 1 ? MBT_MIDDLE : MBT_LEFT;
  host->SendMouseClickEvent(mouse, type, phase == 2, std::max(1, click_count));
}

// An Edit menu command on the focused frame: 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo,
// 6 delete, 7 paste and match style.
inline void Edit(CefRefPtr<CefBrowser> browser, int command) {
  CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
  if (!frame) frame = browser->GetMainFrame();
  if (!frame) return;
  switch (command) {
    case 0: frame->Copy(); break;
    case 1: frame->Cut(); break;
    case 2: frame->Paste(); break;
    case 3: frame->SelectAll(); break;
    case 4: frame->Undo(); break;
    case 5: frame->Redo(); break;
    case 6: frame->Delete(); break;
    case 7: frame->PasteAndMatchStyle(); break;
    default: break;
  }
}

}  // namespace cmux_page_input
