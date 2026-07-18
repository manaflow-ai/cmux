public import AppKit
public import CmuxTerminalDomain

/// Ghostty-free AppKit interaction host for one external terminal runtime.
///
/// The view owns responder focus, physical keyboard translation, and AppKit's
/// `NSTextInputClient` state. Canonical terminal input and preedit state cross
/// the bounded runtime ingress; pixels remain in ``surfaceView``. Pointer,
/// drag, selection, search, copy-mode, and accessibility adapters can share
/// ``enqueueInteraction(_:)`` and ``interactionSnapshot`` without adding a
/// terminal engine to this target.
///
/// AppKit's Objective-C protocol is imported without actor isolation even
/// though an `NSView` text client is invoked on the main thread. The
/// `@preconcurrency` conformance keeps that framework boundary explicit and
/// traps a future off-main callback instead of making mutable UI state unsafe.
@MainActor
public final class TerminalFrontendInteractionView: NSView, @preconcurrency NSTextInputClient {
    /// Fixed ceiling for the only retained text-input buffer.
    ///
    /// Normal IME preedit values are tiny. The ceiling prevents a malformed
    /// input source from turning frontend composition state into unbounded
    /// process memory while preserving complete Unicode scalars.
    static let maximumMarkedTextUTF16Length = 4_096

    /// Ghostty-free pixel surface mounted edge-to-edge behind interaction.
    public let surfaceView: TerminalFrontendSurfaceView

    /// Last synchronous ingress admission observed by this view.
    ///
    /// Rejections are recorded without retrying or blocking AppKit. A later UI
    /// adapter may use this bounded value to surface unavailable-input state.
    public private(set) var lastIngressResult: TerminalExternalIngressResult?

    /// Latest coherent state used by future pointer, selection, copy-mode,
    /// search, and accessibility adapters.
    public var interactionSnapshot: TerminalExternalRuntimeSnapshot {
        runtime.snapshot
    }

    private let runtime: any TerminalExternalRuntime
    private let translator: TerminalFrontendInputTranslator
    private let keyEventInterpreter:
        @MainActor (TerminalFrontendInteractionView, [NSEvent]) -> Void

    private var markedText = NSMutableAttributedString(string: "")
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var activeKeyInterpretation: KeyInterpretation?

    // macOS virtual keycodes occupy the generated 0...127 table. Two words
    // track IME-owned or rejected presses whose releases must not be orphaned.
    private var suppressedReleaseKeyCodesLow: UInt64 = 0
    private var suppressedReleaseKeyCodesHigh: UInt64 = 0

    /// Creates an interaction host with its own visual surface.
    ///
    /// - Parameters:
    ///   - frameRect: Initial bounds in points.
    ///   - runtime: Class-bound canonical runtime. It owns PTY and terminal state.
    public convenience init(
        frame frameRect: NSRect = .zero,
        runtime: any TerminalExternalRuntime
    ) {
        self.init(
            frame: frameRect,
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: frameRect),
            translator: TerminalFrontendInputTranslator(),
            keyEventInterpreter: nil
        )
    }

    /// Creates an interaction host around an injected visual surface.
    ///
    /// - Parameters:
    ///   - frameRect: Initial bounds in points.
    ///   - runtime: Class-bound canonical runtime. It owns PTY and terminal state.
    ///   - surfaceView: Pixel surface to mount behind the event target.
    public convenience init(
        frame frameRect: NSRect = .zero,
        runtime: any TerminalExternalRuntime,
        surfaceView: TerminalFrontendSurfaceView
    ) {
        self.init(
            frame: frameRect,
            runtime: runtime,
            surfaceView: surfaceView,
            translator: TerminalFrontendInputTranslator(),
            keyEventInterpreter: nil
        )
    }

    init(
        frame frameRect: NSRect,
        runtime: any TerminalExternalRuntime,
        surfaceView: TerminalFrontendSurfaceView,
        translator: TerminalFrontendInputTranslator = TerminalFrontendInputTranslator(),
        keyEventInterpreter:
            (@MainActor (TerminalFrontendInteractionView, [NSEvent]) -> Void)?
    ) {
        self.runtime = runtime
        self.surfaceView = surfaceView
        self.translator = translator
        self.keyEventInterpreter = keyEventInterpreter ?? { client, events in
            client.interpretKeyEvents(events)
        }
        super.init(frame: frameRect)

        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
    }

    @available(*, unavailable, message: "Construct with an external terminal runtime")
    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        surfaceView.frame = bounds
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            enqueueInteraction(.focus(true))
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            enqueueInteraction(.focus(false))
        }
        return accepted
    }

    /// Shared ordered mutation seam for the remaining interaction adapters.
    ///
    /// The call performs only synchronous bounded queue admission. It never
    /// waits for IPC, retries a rejection, or claims backend execution.
    @discardableResult
    public func enqueueInteraction(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        let result = runtime.enqueue(mutation)
        lastIngressResult = result
        return result
    }

    public override func keyDown(with event: NSEvent) {
        // A fresh physical press supersedes stale suppression left by a missing
        // key-up. Repeats stay suppressed with their original rejected/IME press.
        if event.isARepeat, isReleaseSuppressed(for: event.keyCode) {
            return
        }
        if !event.isARepeat {
            clearReleaseSuppression(for: event.keyCode)
        }

        // AppKit key interpretation is synchronous. Keeping exactly one active
        // accumulator avoids per-terminal tasks and persistent input history.
        guard activeKeyInterpretation == nil else {
            routePhysicalKey(event, interpretedText: nil)
            return
        }

        let interpretation = KeyInterpretation(
            markedTextWasActive: hasMarkedText()
        )
        activeKeyInterpretation = interpretation
        keyEventInterpreter(self, [event])
        activeKeyInterpretation = nil

        let imeOwnedKey = interpretation.markedTextWasActive
            || interpretation.markedTextMutated
            || hasMarkedText()
        if imeOwnedKey {
            _ = enqueueInOrder(interpretation.committedInputs)
            suppressRelease(for: event.keyCode)
            return
        }

        if let text = interpretation.combinedCommittedText {
            routePhysicalKey(
                event,
                interpretedText: text,
                consumedModifierFlags: event.modifierFlags
            )
            return
        }

        if !interpretation.committedInputs.isEmpty {
            _ = enqueueInOrder(interpretation.committedInputs)
            suppressRelease(for: event.keyCode)
            return
        }

        routePhysicalKey(event, interpretedText: nil)
    }

    public override func keyUp(with event: NSEvent) {
        if consumeReleaseSuppression(for: event.keyCode) {
            return
        }
        routePhysicalKey(event, interpretedText: nil, action: .release)
    }

    public override func flagsChanged(with event: NSEvent) {
        let key = translator.keyEvent(from: event, interpretedText: nil)

        if key.action == .release, consumeReleaseSuppression(for: event.keyCode) {
            return
        }
        if hasMarkedText() {
            if key.action == .press {
                suppressRelease(for: event.keyCode)
            }
            return
        }
        if key.action == .press {
            clearReleaseSuppression(for: event.keyCode)
        }

        let result = enqueueInteraction(.input(.key(key)))
        if key.action == .press, !result.accepted {
            suppressRelease(for: event.keyCode)
        }
    }

    /// Prevents AppKit from beeping for commands whose physical key is routed
    /// after `interpretKeyEvents` returns.
    public override func doCommand(by selector: Selector) {
        _ = selector
    }

    /// Responder-chain committed text used by dictation and accessibility tools.
    public override func insertText(_ insertString: Any) {
        insertText(
            insertString,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        _ = replacementRange
        guard let text = stringValue(from: string) else { return }

        // Committing an empty payload still terminates preedit, matching
        // NSTextInputClient input-manager flush behavior.
        guard clearMarkedText() else { return }
        guard !text.isEmpty else { return }

        let inputs = translator.committedInputs(
            from: text,
            preserveLiteralEscape: false
        )
        if let activeKeyInterpretation {
            activeKeyInterpretation.append(inputs)
        } else {
            _ = enqueueInOrder(inputs)
        }
    }

    public func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        _ = replacementRange
        guard let rawText = stringValue(from: string) else { return }
        let text = boundedMarkedText(rawText)
        guard let preedit = translator.preedit(
            from: text,
            selectedRange: selectedRange
        ) else {
            unmarkText()
            return
        }

        markedText = NSMutableAttributedString(string: preedit.text)
        markedSelectedRange = NSRange(
            location: Int(preedit.selectionStartUTF16),
            length: Int(preedit.selectionLengthUTF16)
        )
        activeKeyInterpretation?.markedTextMutated = true
        enqueueInteraction(.preedit(preedit))
        inputContext?.invalidateCharacterCoordinates()
    }

    public func unmarkText() {
        _ = clearMarkedText()
    }

    @discardableResult
    private func clearMarkedText() -> Bool {
        guard markedText.length > 0 else { return true }
        markedText = NSMutableAttributedString(string: "")
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        activeKeyInterpretation?.markedTextMutated = true
        let accepted = enqueueInteraction(.preedit(nil)).accepted
        inputContext?.invalidateCharacterCoordinates()
        return accepted
    }

    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        guard hasMarkedText() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.length)
    }

    public func selectedRange() -> NSRange {
        if hasMarkedText() {
            return markedSelectedRange
        }
        if let selection = interactionSnapshot.selection {
            return NSRange(location: 0, length: selection.text.utf16.count)
        }
        return NSRange(location: 0, length: 0)
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        if hasMarkedText() {
            guard let clamped = clampedRange(range, length: markedText.length) else {
                return nil
            }
            actualRange?.pointee = clamped
            return markedText.attributedSubstring(from: clamped)
        }

        guard let selection = interactionSnapshot.selection, !selection.text.isEmpty,
              let clamped = clampedRange(range, length: selection.text.utf16.count)
        else { return nil }
        actualRange?.pointee = clamped
        return NSAttributedString(string: selection.text).attributedSubstring(from: clamped)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = selectedRange()
        var localRect = localCursorCellRect()
        if range.length == 0 {
            localRect.size.width = 0
        }

        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return selectedRange().location
    }

    public func attributedString() -> NSAttributedString {
        if hasMarkedText() {
            return NSAttributedString(attributedString: markedText)
        }
        if let selection = interactionSnapshot.selection {
            return NSAttributedString(string: selection.text)
        }
        return NSAttributedString(string: "")
    }

    public func windowLevel() -> Int {
        Int(window?.level.rawValue ?? NSWindow.Level.normal.rawValue)
    }

    private func routePhysicalKey(
        _ event: NSEvent,
        interpretedText: String?,
        consumedModifierFlags: NSEvent.ModifierFlags = [],
        action: TerminalExternalKeyAction? = nil
    ) {
        let key = translator.keyEvent(
            from: event,
            interpretedText: interpretedText,
            consumedModifierFlags: consumedModifierFlags,
            action: action
        )
        let result = enqueueInteraction(.input(.key(key)))
        if key.action == .press, !result.accepted {
            suppressRelease(for: event.keyCode)
        }
    }

    @discardableResult
    private func enqueueInOrder(_ inputs: [TerminalExternalInput]) -> Bool {
        for input in inputs {
            if !enqueueInteraction(.input(input)).accepted {
                return false
            }
        }
        return true
    }

    private func localCursorCellRect() -> NSRect {
        let snapshot = interactionSnapshot
        guard let metrics = snapshot.cellMetrics,
              let cursor = snapshot.cursor,
              metrics.columns > 0,
              metrics.rows > 0,
              metrics.cellWidthPixels > 0,
              metrics.cellHeightPixels > 0
        else {
            return NSRect(x: bounds.minX, y: bounds.minY, width: 0, height: 0)
        }

        let scale = max(metrics.backingScale, 1)
        let cellWidth = Double(metrics.cellWidthPixels) / scale
        let cellHeight = Double(metrics.cellHeightPixels) / scale
        let gridWidth = Double(metrics.columns) * cellWidth
        let gridHeight = Double(metrics.rows) * cellHeight
        let xInset = max((Double(bounds.width) - gridWidth) / 2, 0)
        let yInset = max((Double(bounds.height) - gridHeight) / 2, 0)
        let viewportOffset = snapshot.viewportState?.offset ?? 0
        let viewportRow = cursor.row >= viewportOffset
            ? cursor.row - viewportOffset
            : 0
        let row = min(Int(clamping: viewportRow), metrics.rows - 1)
        let column = min(Int(cursor.column), metrics.columns - 1)
        let topOriginY = yInset + Double(row) * cellHeight

        return NSRect(
            x: Double(bounds.minX) + xInset + Double(column) * cellWidth,
            y: Double(bounds.minY) + Double(bounds.height) - topOriginY - cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    private func stringValue(from value: Any) -> String? {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func boundedMarkedText(_ text: String) -> String {
        guard text.utf16.count > Self.maximumMarkedTextUTF16Length else {
            return text
        }

        var result = ""
        var utf16Length = 0
        for scalar in text.unicodeScalars {
            let scalarLength = scalar.value > 0xFFFF ? 2 : 1
            guard utf16Length + scalarLength <= Self.maximumMarkedTextUTF16Length else {
                break
            }
            result.unicodeScalars.append(scalar)
            utf16Length += scalarLength
        }
        return result
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange? {
        guard range.location != NSNotFound else { return nil }
        let location = min(max(range.location, 0), length)
        let clampedLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: clampedLength)
    }

    private func suppressRelease(for keyCode: UInt16) {
        guard keyCode < 128 else { return }
        if keyCode < 64 {
            suppressedReleaseKeyCodesLow |= UInt64(1) << UInt64(keyCode)
        } else {
            suppressedReleaseKeyCodesHigh |= UInt64(1) << UInt64(keyCode - 64)
        }
    }

    private func clearReleaseSuppression(for keyCode: UInt16) {
        guard keyCode < 128 else { return }
        if keyCode < 64 {
            suppressedReleaseKeyCodesLow &= ~(UInt64(1) << UInt64(keyCode))
        } else {
            suppressedReleaseKeyCodesHigh &= ~(UInt64(1) << UInt64(keyCode - 64))
        }
    }

    private func isReleaseSuppressed(for keyCode: UInt16) -> Bool {
        guard keyCode < 128 else { return false }
        if keyCode < 64 {
            return suppressedReleaseKeyCodesLow & (UInt64(1) << UInt64(keyCode)) != 0
        }
        return suppressedReleaseKeyCodesHigh
            & (UInt64(1) << UInt64(keyCode - 64)) != 0
    }

    private func consumeReleaseSuppression(for keyCode: UInt16) -> Bool {
        guard isReleaseSuppressed(for: keyCode) else { return false }
        clearReleaseSuppression(for: keyCode)
        return true
    }
}

@MainActor
private final class KeyInterpretation {
    let markedTextWasActive: Bool
    private(set) var committedInputs: [TerminalExternalInput] = []
    var markedTextMutated = false

    init(markedTextWasActive: Bool) {
        self.markedTextWasActive = markedTextWasActive
        committedInputs.reserveCapacity(1)
    }

    func append(_ inputs: [TerminalExternalInput]) {
        committedInputs.append(contentsOf: inputs)
    }

    var combinedCommittedText: String? {
        guard !committedInputs.isEmpty else { return nil }
        var result = ""
        for input in committedInputs {
            guard case .text(let text) = input, text.kind == .committed else {
                return nil
            }
            result.append(text.text)
        }
        return result.isEmpty ? nil : result
    }
}
