#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
#else
import AppKit
#endif

// Keys of a hosted page. cmux's KeyRouter decides every key-down first, in
// `CmuxApplication.sendEvent`: app shortcuts (new tab, close, the address bar) run there and never
// reach the page. What it passes on is the page's. A Command or Control chord the page leaves
// unhandled comes back from the host as KEY_UNHANDLED with the input seq of the frame that carried
// it (`CEFShim/src/host_key_seqs.h`): the cmux action held for the page runs (Find after a page with
// no search of its own), else the key goes to the main menu. That is Chrome's unhandled-key path
// (`ui/base/cocoa/command_dispatcher.mm`, `-redispatchKeyEvent:`; out of process, `RedispatchKeyEvent`
// in `components/remote_cocoa/common/native_widget_ns_window.mojom`). The host never asks cmux
// before the page: its key_fn is NULL. All of it waits for ``hostReportsUnhandledKeys``.
extension ChromiumHostPageView {
    /// The key-down `browser` got in the frame with input seq `seq` (KEY_UNHANDLED's request), which
    /// the page left unhandled; it is released. Nil when this view holds no such key.
    func takeUnhandledKey(seq: UInt32, browser: Int32) -> NSEvent? {
        keyDowns.take(seq, browser: browser)
    }

    /// Gives `event`, a key the page left unhandled that no held cmux action took, to
    /// ``redispatchTarget``; meanwhile the view does not take it back for the page.
    ///
    /// - Returns: Whether the target handled it.
    @discardableResult
    func redispatch(_ event: NSEvent) -> Bool {
        isRedispatching = true
        defer { isRedispatching = false }
        return redispatchTarget(event)
    }

    /// Whether a key-down is one the page may report back: a Command or Control chord (the keys
    /// cmux shortcuts and menus use).
    nonisolated static func reportsUnhandled(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.isDisjoint(with: [.command, .control])
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its wire.
extension ChromiumHostPageView {
    public override func keyDown(with event: NSEvent) { key(event, phase: 0) }
    public override func keyUp(with event: NSEvent) { key(event, phase: 1) }
    public override func flagsChanged(with event: NSEvent) { key(event, phase: 2) }

    /// A Command or Control chord while this view has the keyboard goes to the page, as Chrome's
    /// page view takes key equivalents (`-[RenderWidgetHostViewCocoa performKeyEquivalent:]`,
    /// `content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`): the KeyRouter ran before
    /// AppKit offered it, and the menu sees the key only when the page leaves it unhandled. Only while
    /// the host reports such keys back; else the menu keeps them.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, inputTarget == .view, hostReportsUnhandledKeys, !isRedispatching,
              window?.firstResponder === self, Self.reportsUnhandled(event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }
        key(event, phase: 0)
        return true
    }

    /// One key frame: v0 phase, v1 key code, v2 repeat. A key-down goes to the input method first
    /// (ChromiumHostPageView+TextInput.swift), which decides the frames that carry it. A chord
    /// key-down is held under the browser and input seq the writer stamped on the frame that
    /// carries the key itself, for the host's report.
    private func key(_ event: NSEvent, phase: Int32) {
        if exclusiveAccess.takesEscape(event, phase: phase) { return }
        var frame = ChromiumHostFrame(.key, v: [phase, Int32(event.keyCode), event.type == .flagsChanged ? 0 : (event.isARepeat ? 1 : 0)],
                                      flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp))
        if event.type != .flagsChanged {
            frame.ch = ChromiumHostTextInput.keyCharacter(event.characters)
            frame.unmod = ChromiumHostTextInput.keyCharacter(event.charactersIgnoringModifiers)
        }
        guard phase == 0 else {
            sendInput(frame)
            return
        }
        let receipt = textInputKeyDown(event, key: frame)
        if hostReportsUnhandledKeys, Self.reportsUnhandled(event.modifierFlags), let receipt {
            keyDowns.record(event, receipt)
        }
    }
}
#endif
