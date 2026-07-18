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
public final class TerminalFrontendInteractionView: NSView, @preconcurrency NSTextInputClient,
    NSUserInterfaceValidations
{
    /// Fixed ceiling for the only retained text-input buffer.
    ///
    /// Normal IME preedit values are tiny. The ceiling prevents a malformed
    /// input source from turning frontend composition state into unbounded
    /// process memory while preserving complete Unicode scalars.
    static let maximumMarkedTextUTF16Length = 4_096

    /// Canonical daemon ceiling for repeat counts and one-shot scroll amounts.
    static let maximumCommandCount: UInt32 = 10_000

    /// Canonical daemon ceiling for retained search-query bytes.
    static let maximumSearchQueryUTF8Length = 65_536

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
    private let interactionAdapter: TerminalFrontendInteractionAdapter
    private let keyEventInterpreter:
        @MainActor (TerminalFrontendInteractionView, [NSEvent]) -> Void
    let accessibilityBridge: TerminalFrontendAccessibilityBridge

    private var markedText = NSMutableAttributedString(string: "")
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var activeKeyInterpretation: KeyInterpretation?
    private var clipboardActionTask: Task<Void, Never>?
    private var pointerTrackingArea: NSTrackingArea?

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
        clipboardWriter: any TerminalFrontendClipboardWriting =
            TerminalFrontendSystemClipboardWriter(),
        clipboardReader: any TerminalFrontendClipboardReading =
            TerminalFrontendSystemClipboardReader(),
        accessibilityLinkOpener: (@MainActor (String) -> Bool)? = nil,
        keyEventInterpreter:
            (@MainActor (TerminalFrontendInteractionView, [NSEvent]) -> Void)?
    ) {
        self.runtime = runtime
        self.surfaceView = surfaceView
        self.translator = translator
        self.interactionAdapter = TerminalFrontendInteractionAdapter(
            runtime: runtime,
            translator: translator,
            clipboardWriter: clipboardWriter,
            clipboardReader: clipboardReader
        )
        accessibilityBridge = TerminalFrontendAccessibilityBridge(
            linkOpener: accessibilityLinkOpener ?? Self.openAccessibilityLink
        )
        self.keyEventInterpreter = keyEventInterpreter ?? { client, events in
            client.interpretKeyEvents(events)
        }
        super.init(frame: frameRect)

        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
        accessibilityBridge.bind(to: self)
    }

    @available(*, unavailable, message: "Construct with an external terminal runtime")
    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        surfaceView.frame = bounds
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .inVisibleRect,
                .activeInKeyWindow,
                .mouseMoved,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
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
            interactionAdapter.cancelPointerInteractions()
            enqueueInteraction(.focus(false))
        }
        return accepted
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            interactionAdapter.cancelAllInteractions()
            clipboardActionTask?.cancel()
            clipboardActionTask = nil
            accessibilityBridge.stopObservation()
        }
    }

    // MARK: - Accessibility

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityValue() -> Any? {
        accessibilityBridge.snapshot()?.text
            ?? interactionSnapshot.visibleText
            ?? interactionSnapshot.selection?.text
            ?? ""
    }

    public override func setAccessibilityValue(_ value: Any?) {
        guard window != nil else { return }
        let text: String
        switch value {
        case let value as NSAttributedString:
            text = value.string
        case let value as String:
            text = value
        default:
            return
        }
        guard !text.isEmpty else { return }
        insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        guard let snapshot = accessibilityBridge.snapshot() else {
            return selectedRange()
        }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).selectedRange
    }

    public override func accessibilitySelectedText() -> String? {
        guard let snapshot = accessibilityBridge.snapshot() else {
            let text = interactionSnapshot.selection?.text ?? ""
            return text.isEmpty ? nil : text
        }
        let text = snapshot.selections.first?.text ?? ""
        return text.isEmpty ? nil : text
    }

    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        guard let snapshot = accessibilityBridge.snapshot() else {
            return [NSValue(range: selectedRange())]
        }
        let model = TerminalFrontendAccessibilityTextModel(snapshot: snapshot)
        if model.selectedRanges.isEmpty,
           let insertion = snapshot.cursor?.insertionRange {
            let range = NSRange(location: insertion.location, length: insertion.length)
            guard TerminalFrontendAccessibilityTextModel.isValid(
                range,
                maximum: model.utf16Length
            ) else { return [] }
            return [NSValue(range: range)]
        }
        return model.selectedRanges.map(NSValue.init(range:))
    }

    public override func accessibilityNumberOfCharacters() -> Int {
        guard let snapshot = accessibilityBridge.snapshot() else {
            return ((accessibilityValue() as? String) ?? "").utf16.count
        }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).utf16Length
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    public override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityBridge.snapshot()?.cursor?.line ?? 0
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        guard let snapshot = accessibilityBridge.snapshot() else { return nil }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).string(for: range)
    }

    public override func accessibilityAttributedString(
        for range: NSRange
    ) -> NSAttributedString? {
        guard let text = accessibilityString(for: range) else { return nil }
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                ),
            ]
        )
    }

    public override func accessibilityLine(for index: Int) -> Int {
        guard let snapshot = accessibilityBridge.snapshot() else { return NSNotFound }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).line(for: index)
    }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let snapshot = accessibilityBridge.snapshot() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).range(forLine: line)
    }

    public override func accessibilityRange(for index: Int) -> NSRange {
        guard let snapshot = accessibilityBridge.snapshot() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).composedRange(
            for: index
        )
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let snapshot = accessibilityBridge.snapshot() else { return .zero }
        return accessibilityBridge.frame(for: range, snapshot: snapshot) ?? .zero
    }

    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let snapshot = accessibilityBridge.snapshot() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityBridge.range(forScreenPoint: point, snapshot: snapshot)
            ?? NSRange(location: NSNotFound, length: 0)
    }

    public override func isAccessibilityFocused() -> Bool {
        accessibilityBridge.snapshot()?.focused ?? window?.firstResponder === self
    }

    public override func setAccessibilityFocused(_ focused: Bool) {
        guard focused else { return }
        window?.makeFirstResponder(self)
    }

    public override func accessibilityChildren() -> [Any]? {
        accessibilityBridge.children()
    }

    deinit {
        clipboardActionTask?.cancel()
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

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recordIngressIfPresent(
            interactionAdapter.pointerDown(event, button: .left, in: self)
        )
    }

    public override func mouseUp(with event: NSEvent) {
        recordIngressIfPresent(
            interactionAdapter.pointerUp(event, button: .left, in: self)
        )
    }

    public override func mouseDragged(with event: NSEvent) {
        recordIngressIfPresent(
            interactionAdapter.pointerDragged(event, button: .left, in: self)
        )
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard interactionSnapshot.mouseTracking else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        recordIngressIfPresent(
            interactionAdapter.pointerDown(event, button: .right, in: self)
        )
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard interactionAdapter.hasPressedButton(.right) else {
            super.rightMouseUp(with: event)
            return
        }
        recordIngressIfPresent(
            interactionAdapter.pointerUp(event, button: .right, in: self)
        )
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard interactionAdapter.hasPressedButton(.right) else {
            super.rightMouseDragged(with: event)
            return
        }
        recordIngressIfPresent(
            interactionAdapter.pointerDragged(event, button: .right, in: self)
        )
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        recordIngressIfPresent(
            interactionAdapter.pointerDown(event, button: .middle, in: self)
        )
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2,
              interactionAdapter.hasPressedButton(.middle)
        else {
            super.otherMouseUp(with: event)
            return
        }
        recordIngressIfPresent(
            interactionAdapter.pointerUp(event, button: .middle, in: self)
        )
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2,
              interactionAdapter.hasPressedButton(.middle)
        else {
            super.otherMouseDragged(with: event)
            return
        }
        recordIngressIfPresent(
            interactionAdapter.pointerDragged(event, button: .middle, in: self)
        )
    }

    public override func mouseMoved(with event: NSEvent) {
        recordIngressIfPresent(interactionAdapter.pointerMoved(event, in: self))
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        recordIngressIfPresent(interactionAdapter.pointerMoved(event, in: self))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        recordIngressIfPresent(interactionAdapter.pointerExited(event, in: self))
    }

    public override func scrollWheel(with event: NSEvent) {
        recordIngressIfPresent(interactionAdapter.scrollWheel(event, in: self))
    }

    /// Releases every admitted pointer button once and clears bounded gesture state.
    public func cancelPointerInteractions() {
        recordIngressIfPresent(interactionAdapter.cancelPointerInteractions())
    }

    /// Enqueues one canonical selection command without blocking AppKit.
    @discardableResult
    public func performSelection(
        _ operation: TerminalExternalSelectionOperation
    ) -> TerminalExternalIngressResult {
        recordIngress(interactionAdapter.performSelection(operation))
    }

    /// Enqueues one bounded canonical copy-mode command.
    @discardableResult
    public func performCopyMode(
        _ operation: TerminalExternalCopyModeOperation,
        adjustment: TerminalExternalCopyModeAdjustment? = nil,
        count: UInt32 = 1
    ) -> TerminalExternalIngressResult {
        recordIngress(interactionAdapter.performCopyMode(
            operation,
            adjustment: adjustment,
            count: count
        ))
    }

    /// Enqueues one canonical search command with a scalar-safe byte ceiling.
    @discardableResult
    public func performSearch(
        _ operation: TerminalExternalSearchOperation,
        query: String? = nil
    ) -> TerminalExternalIngressResult {
        recordIngress(interactionAdapter.performSearch(operation, query: query))
    }

    /// Enqueues one bounded canonical scroll command.
    @discardableResult
    public func performScroll(
        _ operation: TerminalExternalScrollOperation,
        amount: Int64? = nil
    ) -> TerminalExternalIngressResult {
        recordIngress(interactionAdapter.performScroll(operation, amount: amount))
    }

    /// Reads the canonical selection asynchronously and writes nonempty text once.
    public func copySelectionToClipboard() async -> Bool {
        await interactionAdapter.copySelectionToClipboard()
    }

    /// Reads canonical selection text without blocking AppKit's responder chain.
    @IBAction public func copy(_ sender: Any?) {
        _ = sender
        clipboardActionTask?.cancel()
        clipboardActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.interactionAdapter.copySelectionToClipboard()
        }
    }

    /// Admits one clipboard value to the backend as paste input.
    @IBAction public func paste(_ sender: Any?) {
        _ = sender
        guard clearMarkedText() else { return }
        recordIngressIfPresent(interactionAdapter.pasteClipboardText())
    }

    /// Selects canonical terminal contents through the shared mutation path.
    @IBAction public func selectAll(_ sender: Any?) {
        _ = sender
        recordIngress(interactionAdapter.performSelection(.selectAll))
    }

    /// Enables edit-menu actions only when their lightweight prerequisites exist.
    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            interactionAdapter.hasCopyableSelection
        case #selector(paste(_:)):
            interactionAdapter.hasPasteboardText
        case #selector(selectAll(_:)):
            interactionSnapshot.lifecycle == .live
        default:
            true
        }
    }

    /// Latest revision-fenced accessibility value in the coherent runtime snapshot.
    public var terminalAccessibilitySnapshot: TerminalAccessibilitySnapshot? {
        interactionSnapshot.accessibility
    }

    /// Enables demand-driven accessibility production in the canonical runtime.
    public func enableTerminalAccessibility() {
        interactionAdapter.enableTerminalAccessibility()
    }

    /// Forwards the runtime's bounded newest-only accessibility stream.
    public func terminalAccessibilitySnapshots()
        -> AsyncStream<TerminalAccessibilitySnapshot> {
        interactionAdapter.terminalAccessibilitySnapshots()
    }

    /// Revalidates an action against the exact currently presented snapshot.
    public func activateTerminalAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        guard interactionSnapshot.accessibility == snapshot,
              snapshot.links.contains(link)
        else { return nil }
        return await interactionAdapter.activateTerminalAccessibilityLink(
            link,
            snapshot: snapshot
        )
    }

    @discardableResult
    private func recordIngress(
        _ result: TerminalExternalIngressResult
    ) -> TerminalExternalIngressResult {
        lastIngressResult = result
        return result
    }

    private func recordIngressIfPresent(
        _ result: TerminalExternalIngressResult?
    ) {
        guard let result else { return }
        lastIngressResult = result
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

        if interpretation.commandHandled {
            suppressRelease(for: event.keyCode)
            return
        }

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

    /// Handles standard edit selectors and leaves other physical keys on the
    /// semantic backend input path after `interpretKeyEvents` returns.
    public override func doCommand(by selector: Selector) {
        let handled: Bool
        switch selector {
        case #selector(copy(_:)):
            copy(nil)
            handled = true
        case #selector(paste(_:)):
            paste(nil)
            handled = true
        case #selector(selectAll(_:)):
            selectAll(nil)
            handled = true
        default:
            handled = false
        }
        activeKeyInterpretation?.commandHandled = handled
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
        let xInset = metrics.paddingLeftPixels.map {
            max(Double($0) / scale, 0)
        } ?? max((Double(bounds.width) - gridWidth) / 2, 0)
        let topInset = metrics.paddingTopPixels.map {
            max(Double($0) / scale, 0)
        } ?? max((Double(bounds.height) - gridHeight) / 2, 0)
        let viewportOffset = snapshot.viewportState?.offset ?? 0
        let viewportRow = cursor.row >= viewportOffset
            ? cursor.row - viewportOffset
            : 0
        let row = min(Int(clamping: viewportRow), metrics.rows - 1)
        let column = min(Int(cursor.column), metrics.columns - 1)
        let topOriginY = topInset + Double(row) * cellHeight

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

    private static func openAccessibilityLink(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = NSString(string: trimmed).isAbsolutePath
            ? URL(fileURLWithPath: trimmed)
            : URL(string: trimmed)
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class KeyInterpretation {
    let markedTextWasActive: Bool
    private(set) var committedInputs: [TerminalExternalInput] = []
    var markedTextMutated = false
    var commandHandled = false

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
