#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
public import AppKit
import Carbon.HIToolbox
import CmuxNextWakeups

/// The page's `NSTextInputClient` in host mode
/// (plans/cmux-next/chrome-parity/p01-process.md 3.3, task 043): input
/// methods, dead keys, the emoji picker and dictation talk to this view, as
/// they talk to Chrome's `RenderWidgetHostViewCocoa`
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm), whose
/// rules ``ChromiumHostTextInput`` keeps. What the input method changes goes
/// to the host as ops on the ordered stream (``textInputSink``); what it asks
/// (selection, marked range, text, character rects) is answered from the
/// state the host pushed ahead (``applyTextInputState(_:)``). No method here
/// sends and waits: Chrome's two sync calls (`SyncGetFirstRectForRange`,
/// `SyncGetCharacterIndexAtPoint`) have no counterpart.
extension ChromiumHostPageView: NSTextInputClient {
    // MARK: Turns

    /// A key down: the input method sees it first, then the key goes to the
    /// host as its calls decided (a plain key, a process key and a
    /// composition, a commit).
    ///
    /// - Returns: Where the writer put the frame that carries the key itself
    ///   (a plain key down), nil when no frame does or the writer stamped none.
    func textInputKeyDown(_ event: NSEvent, key: ChromiumHostFrame) -> ChromiumHostInputReceipt? { // perf-hot: 1ms cef-host-input (every key typed into a hosted page)
        textInput.beginKey()
        interpretKeyEvents([event])
        let controlOrCommand = !event.modifierFlags.isDisjoint(with: [.control, .command])
        return deliver(textInput.endKey(key, controlOrCommand: controlOrCommand))
    }

    /// Takes the host's TEXT_INPUT_STATE push (task 044).
    func applyTextInputState(_ state: ChromiumHostTextInputState) {
        // The context before the push: a push with no field focused takes it away.
        let context = inputContext
        let applied = textInput.apply(state)
        if applied.discardMarkedText { context?.discardMarkedText() }
        if applied.invalidateCharacterCoordinates { context?.invalidateCharacterCoordinates() }
        updatePasswordInput()
    }

    /// A mouse down while composing, before the down goes to the page: the
    /// composition ends with its text kept and the input method drops its
    /// marked text, so the caret never moves with a composition open. The
    /// click is not offered to the input method: Chrome's
    /// `-[RenderWidgetHostViewCocoa mouseEvent:]` calls `finishComposingText`
    /// and sends the down.
    func textInputMouseDown() {
        guard textInput.hasMarkedText else { return }
        let context = inputContext
        let outputs = textInput.finishComposition()
        context?.discardMarkedText()
        deliver(outputs)
    }

    /// The page lost focus: the page ends its own composition on blur, so the
    /// input method drops its marked text and nothing goes to the host
    /// (Chrome's `cancelComposition` from `resignFirstResponder`).
    func textInputDidResign() {
        let context = inputContext
        if textInput.cancelComposition() { context?.discardMarkedText() }
    }

    /// Sends `outputs` in order. Returns the receipt of the plain key down among them.
    @discardableResult
    private func deliver(_ outputs: [ChromiumHostTextInput.Output]) -> ChromiumHostInputReceipt? {
        var carried: ChromiumHostInputReceipt?
        for output in outputs {
            switch output {
            case .key(let frame):
                let receipt = sendInput(frame)
                if frame.v[0] == 0, frame.v[3] == ChromiumHostTextInput.KeyMark.plain.rawValue { carried = receipt }
            case .op(let op):
                flushWaitingInput()  // the moves and wheel ticks before it keep their place
                textInputSink?(op)
            }
        }
        return carried
    }

    /// None while no field can take an input method (no text field focused,
    /// a password field): key bindings still type there.
    public override var inputContext: NSTextInputContext? {
        textInput.state.type.takesInputMethod ? super.inputContext : nil
    }

    // MARK: Secure event input

    /// Secure event input on exactly while a password field has focus here: the
    /// pushed type is password (a host that ended pushed no field), this view is
    /// first responder of a window and that window is key
    /// (``ChromiumHostPasswordInput``). Hiding the view takes its first
    /// responder status (AppKit's `isHidden`), so a hidden page is a blurred one.
    func updatePasswordInput() {
        guard textInput.state.type == .password, passwordInput.focused, let window else {
            passwordInput.keyWatch = []
            passwordInput.turn(false)
            return
        }
        if passwordInput.keyWatch.isEmpty {
            let events = WindowEvents.of(window, center: passwordInput.windowCenter)
            let owner = "ChromiumHostPageView.passwordInput"
            passwordInput.keyWatch = [
                events.subscribe(NSWindow.didBecomeKeyNotification, owner: owner) { [weak self] in self?.updatePasswordInput() },
                events.subscribe(NSWindow.didResignKeyNotification, owner: owner) { [weak self] in self?.updatePasswordInput() },
            ]
        }
        passwordInput.turn(passwordInput.isKey(window))
    }

    /// The view moved to another window or out of every window: the key watch was the old window's, and the
    /// focus is what the new window says (AppKit need not tell a view that leaves a window that it resigned),
    /// as Chrome reads `[[self window] firstResponder] == self` (render_widget_host_view_cocoa.mm).
    func passwordInputWindowChanged() {
        passwordInput.keyWatch = []
        passwordInput.focused = window?.firstResponder === self
        updatePasswordInput()
    }

    // MARK: Caret accessory

    /// macOS 14's caret bubble over a cmux page stays hidden, as on Chromium's
    /// own view of one; a web page keeps the system's placement
    /// (``ChromiumPageTextAccessory/placement(showsCmuxPage:)``). The page's
    /// owner says which page shows (``showsCmuxPage``).
    public func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement {
        ChromiumPageTextAccessory.placement(showsCmuxPage: showsCmuxPage())
    }

    // MARK: NSTextInputClient: changes

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.plainText(string) else { return }
        deliver(textInput.insertText(text, replacement: Self.range(replacementRange)))
    }

    /// With no input context (no field, a password field) AppKit's key
    /// bindings call NSResponder's one-argument form (Chrome forwards it the same way).
    public override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let text = Self.plainText(string) else { return }
        let length = text.utf16.count
        let clauses = (string as? NSAttributedString).map(ChromiumHostCompositionClause.clauses(of:))
            ?? [ChromiumHostCompositionClause(range: 0..<length, thick: false)]
        let selection = Self.range(selectedRange) ?? length..<length
        deliver(textInput.setMarkedText(text, clauses: clauses, selection: selection,
                                        replacement: Self.range(replacementRange)))
    }

    public func unmarkText() {
        deliver(textInput.unmarkText())
    }

    public override func doCommand(by selector: Selector) {
        deliver(textInput.doCommand(NSStringFromSelector(selector)))
    }

    /// Chrome's set: the underlines an input method marks clauses with, and the replacement range.
    /// AppKit's `NSTextInputReplacementRangeAttributeName` does not import into Swift, so the key is
    /// spelled by its value.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment, Self.textInputReplacementRangeKey]
    }

    /// `NSTextInputReplacementRangeAttributeName` (NSTextInputClient.h).
    static let textInputReplacementRangeKey = NSAttributedString.Key("NSTextInputReplacementRangeAttributeName")

    // MARK: NSTextInputClient: questions, from pushed state only

    public func hasMarkedText() -> Bool {
        textInput.hasMarkedText
    }

    public func markedRange() -> NSRange {
        Self.nsRange(textInput.markedRange)
    }

    public func selectedRange() -> NSRange {
        Self.nsRange(textInput.state.selection)
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // SAFETY: AppKit's out-parameter, an NSRange it owns for this call (NSTextInputClient); NULL is skipped.
        unsafe actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        guard let requested = Self.range(range), let found = textInput.substring(of: requested) else { return nil }
        // SAFETY: as above.
        unsafe actualRange?.pointee = Self.nsRange(found.actual)
        return NSAttributedString(string: found.text)
    }

    /// The rect in screen points (where the candidate window and the
    /// dictation indicator go).
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let requested = Self.range(range) ?? (textInput.state.selection ?? 0..<0)
        let found = textInput.firstRect(for: requested)
        // SAFETY: AppKit's out-parameter, an NSRange it owns for this call (NSTextInputClient); NULL is skipped.
        unsafe actualRange?.pointee = Self.nsRange(found.actual)
        let page = found.rect
        // Page points have a top-left origin; this view's are bottom-left.
        let local = NSRect(x: page.minX, y: bounds.height - page.maxY, width: page.width, height: page.height)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return textInput.characterIndex(at: CGPoint(x: local.x, y: bounds.height - local.y)) ?? NSNotFound
    }

    // MARK: Conversions

    private static func plainText(_ string: Any) -> String? {
        switch string {
        case let attributed as NSAttributedString: attributed.string
        case let plain as String: plain
        default: nil
        }
    }

    /// A range an input method passed; nil for NSNotFound or one that does not fit.
    static func range(_ range: NSRange) -> Range<Int>? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return range.location..<(range.location + range.length)
    }

    static func nsRange(_ range: Range<Int>?) -> NSRange {
        guard let range else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: range.lowerBound, length: range.count)
    }
}

/// Secure event input for the page's password fields
/// (plans/cmux-next/chrome-parity/p01-process.md item 16, task 230). While a
/// password field has focus the frontmost process turns it on, so no event tap
/// in another process reads the keys. Chrome's browser process holds a
/// `ui::ScopedPasswordInputEnabler` (ui/base/cocoa/secure_password_input.mm)
/// while its focused view in the active window has a TEXT_INPUT_TYPE_PASSWORD
/// field (`RenderWidgetHostViewMac::SetTextInputActive`,
/// content/browser/renderer_host/render_widget_host_view_mac.mm). In host mode
/// cmux is the frontmost process, not the host, so the page view holds it.
struct ChromiumHostPasswordInput {
    /// The system's secure event input switch; tests pass a recorder.
    nonisolated struct Switch: Sendable {
        let enable: @Sendable () -> Void
        let disable: @Sendable () -> Void

        /// HIToolbox's `EnableSecureEventInput` and `DisableSecureEventInput` (counted per process, so each
        /// page view's enable and disable pair stays balanced beside the terminals' `TerminalSecureInput`).
        static let carbon = Switch(enable: { _ = EnableSecureEventInput() }, disable: { _ = DisableSecureEventInput() })
    }

    /// Secure event input on for its life: one enable when made, one disable when released (the view's
    /// release included), as Chrome's scoped enabler.
    nonisolated final class Enabler {
        private let system: Switch

        init(_ system: Switch) {
            self.system = system
            system.enable()
        }

        deinit { system.disable() }
    }

    var system: Switch = .carbon
    /// Where windows post their key changes (``WindowEvents/of(_:center:)``); tests pass their own.
    var windowCenter: NotificationCenter = .default
    /// Whether a window is the key window; tests pass their own (a test window never becomes key).
    var isKey: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow }
    /// The view is its window's first responder.
    var focused = false
    /// The window's key changes, watched only while a password field has focus.
    var keyWatch: [EventSubscription] = []
    /// Held while secure event input is on.
    private(set) var enabler: Enabler?

    /// Whether this view holds secure event input now (`debug.chromium_host` `password_input`).
    var isOn: Bool { enabler != nil }

    mutating func turn(_ on: Bool) {
        if !on {
            enabler = nil
        } else if enabler == nil {
            enabler = Enabler(system)
        }
    }
}

extension ChromiumHostCompositionClause {
    /// The clauses an input method marked with underlines, thick for the
    /// selected one (Chrome's `ExtractUnderlines`).
    static func clauses(of string: NSAttributedString) -> [ChromiumHostCompositionClause] {
        var clauses: [ChromiumHostCompositionClause] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            guard let style = attributes[.underlineStyle] as? NSNumber else { return }
            var clause = ChromiumHostCompositionClause(range: range.location..<NSMaxRange(range), thick: style.intValue > 1)
            if let color = (attributes[.underlineColor] as? NSColor)?.usingColorSpace(.sRGB) {
                clause.color = argb(color)
            }
            clauses.append(clause)
        }
        return clauses
    }

    private static func argb(_ color: NSColor) -> UInt32 {
        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        return byte(color.alphaComponent) << 24 | byte(color.redComponent) << 16 | byte(color.greenComponent) << 8
            | byte(color.blueComponent)
    }
}
#endif
