#if os(iOS)
import Foundation
import GhosttyNextKit
import UIKit

/// Runs the router's actions on the Ghostty surface: keys through the key
/// encoder, committed text as typed, pastes as pastes, marked text as preedit.
/// Ghostty writes the encoded bytes to `io_write_cb` on this thread (D6),
/// which reaches `onInput`.
extension TerminalSurfaceView {
    func perform(_ actions: [TerminalInputAction]) {
        guard let surface else { return }
        // Something the person typed, pressed or pasted (not a key release
        // or preedit). Ghostty's own replies to terminal queries also reach
        // `onInput`, but never pass through here.
        if actions.contains(where: \.isUserInput) { onUserInput?() }
        for action in actions {
            switch action {
            case .key(let event):
                Self.withCString(event.text) { text in
                    var key = ghostty_input_key_s()
                    key.action = event.isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
                    key.mods = Self.ghosttyMods(event.mods)
                    key.consumed_mods = GHOSTTY_MODS_NONE
                    key.keycode = event.keyCode
                    key.text = text
                    key.unshifted_codepoint = event.unshiftedCodepoint
                    key.composing = false
                    _ = ghostty_surface_key(surface, key)
                }
            case .text(let text):
                Self.withBytes(text) { ghostty_surface_text_input(surface, $0, $1) }
            case .paste(let text):
                Self.withBytes(text) { ghostty_surface_text(surface, $0, $1) }
            case .preedit(let text):
                Self.withBytes(text) { ghostty_surface_preedit(surface, $0, $1) }
                requestRedraw()
            }
        }
    }

    /// A trackpad wheel at `point` (this view's points), `deltaY` points
    /// (positive scrolls up, toward older content), through Ghostty's own
    /// scroll path (T-SCROLL-12): an app that asked for the mouse gets wheel
    /// reports at that cell, the alternate screen with alternate scroll gets
    /// cursor keys, and the bytes reach `onInput`. Ghostty keeps the part of a
    /// row not yet sent for the next event.
    func scrollWheel(at point: CGPoint, deltaY: CGFloat, momentum: TerminalTUIScroll.Momentum) {
        guard let surface else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_scroll(surface, 0, Double(deltaY * scale), ghostty_input_scroll_mods_t(TerminalTUIScroll.mods(momentum)))
    }

    /// A tap at `point` (this view's points) as a left click, press then
    /// release, when the app asked for the mouse (TUI capability F1: vim
    /// `mouse=a`, htop's header, mc, tmux panes). Ghostty encodes it in the
    /// app's mouse mode. Returns false, sending nothing, when no app
    /// captures the mouse.
    /// An app on the screen asked for the mouse (a tap is its click, not a link's).
    var capturesMouse: Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    @discardableResult
    func click(at point: CGPoint) -> Bool {
        guard let surface, ghostty_surface_mouse_captured(surface) else { return false }
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        return true
    }

    static func ghosttyMods(_ mods: TerminalKeyMods) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if mods.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if mods.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if mods.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if mods.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func withCString(_ text: String?, _ body: (UnsafePointer<CChar>?) -> Void) {
        guard let text, !text.isEmpty else { return body(nil) }
        text.withCString { body($0) }
    }

    private static func withBytes(_ text: String, _ body: (UnsafePointer<CChar>, UInt) -> Void) {
        let utf8 = Array(text.utf8CString)
        utf8.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            body(base, UInt(buffer.count - 1))
        }
    }

    /// The cursor cell in this view's points (the IME candidate window and
    /// the keyboard pan use it).
    var cursorRect: CGRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // x is the cell's midpoint and y its bottom (Ghostty's IME point).
        return CGRect(x: x - width / 2, y: y - height, width: max(width, 1), height: height)
    }
}

/// Modifier flags UIKit reports, as the router's modifiers.
extension TerminalKeyMods {
    init(_ flags: UIKeyModifierFlags) {
        var mods: TerminalKeyMods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.alternate) { mods.insert(.alternate) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }
}
#endif
