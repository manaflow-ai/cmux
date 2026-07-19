internal import AppKit
internal import CmuxTerminalDomain

/// Fixed-memory adapter from AppKit gestures to ordered runtime mutations.
///
/// The adapter retains only three admitted-button bits, one pointer sample,
/// and one sub-row scroll remainder. Canonical selection, copy mode, search,
/// viewport, and accessibility state remain in the external runtime.
@MainActor
final class TerminalFrontendInteractionAdapter {
    private static let maximumWheelEventsPerAppKitEvent = 32

    private let runtime: any TerminalExternalRuntime
    private let translator: TerminalFrontendInputTranslator
    private let clipboardWriter: any TerminalFrontendClipboardWriting
    private let clipboardReader: any TerminalFrontendClipboardReading

    private var pressedButtonBits: UInt8 = 0
    private var lastPointerSample = PointerSample.zero
    private var preciseVerticalRemainderPoints = 0.0
    private var preservesRemainderForMomentum = false

    init(
        runtime: any TerminalExternalRuntime,
        translator: TerminalFrontendInputTranslator,
        clipboardWriter: any TerminalFrontendClipboardWriting,
        clipboardReader: any TerminalFrontendClipboardReading
    ) {
        self.runtime = runtime
        self.translator = translator
        self.clipboardWriter = clipboardWriter
        self.clipboardReader = clipboardReader
    }

    func hasPressedButton(_ button: TerminalExternalMouseButton) -> Bool {
        let bit = buttonBit(button)
        return bit != 0 && pressedButtonBits & bit != 0
    }

    @discardableResult
    func pointerDown(
        _ event: NSEvent,
        button: TerminalExternalMouseButton,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        let bit = buttonBit(button)
        guard bit != 0 else { return nil }
        let sample = pointerSample(event, in: view)
        lastPointerSample = sample

        // A second physical press supersedes a missing AppKit release. Emit at
        // most one synthetic release before admitting the replacement press.
        if pressedButtonBits & bit != 0 {
            pressedButtonBits &= ~bit
            _ = enqueueMouse(
                action: .release,
                button: button,
                sample: sample,
                anyButtonPressed: pressedButtonBits != 0
            )
        }

        let result = enqueueMouse(
            action: .press,
            button: button,
            sample: sample,
            anyButtonPressed: true
        )
        if result.accepted {
            pressedButtonBits |= bit
        }
        return result
    }

    @discardableResult
    func pointerUp(
        _ event: NSEvent,
        button: TerminalExternalMouseButton,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        let bit = buttonBit(button)
        guard bit != 0, pressedButtonBits & bit != 0 else { return nil }
        let sample = pointerSample(event, in: view)
        lastPointerSample = sample
        pressedButtonBits &= ~bit
        return enqueueMouse(
            action: .release,
            button: button,
            sample: sample,
            anyButtonPressed: pressedButtonBits != 0
        )
    }

    @discardableResult
    func pointerDragged(
        _ event: NSEvent,
        button: TerminalExternalMouseButton,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        guard hasPressedButton(button) else { return nil }
        let sample = pointerSample(event, in: view)
        lastPointerSample = sample
        return enqueueMouse(
            action: .motion,
            button: button,
            sample: sample,
            anyButtonPressed: true
        )
    }

    @discardableResult
    func pointerMoved(
        _ event: NSEvent,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        let sample = pointerSample(event, in: view)
        lastPointerSample = sample
        guard runtime.snapshot.mouseTracking || pressedButtonBits != 0 else {
            return nil
        }
        return enqueueMouse(
            action: .motion,
            button: nil,
            sample: sample,
            anyButtonPressed: pressedButtonBits != 0
        )
    }

    @discardableResult
    func pointerExited(
        _ event: NSEvent,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        pointerMoved(event, in: view)
    }

    /// Releases admitted buttons in stable left, right, middle order.
    ///
    /// Rejections are not retried, and local ownership is cleared before each
    /// enqueue so an unavailable backend cannot create an orphan retry loop.
    @discardableResult
    func cancelPointerInteractions() -> TerminalExternalIngressResult? {
        var lastResult: TerminalExternalIngressResult?
        for button in [
            TerminalExternalMouseButton.left,
            .right,
            .middle,
        ] where hasPressedButton(button) {
            let bit = buttonBit(button)
            pressedButtonBits &= ~bit
            lastResult = enqueueMouse(
                action: .release,
                button: button,
                sample: lastPointerSample,
                anyButtonPressed: pressedButtonBits != 0
            )
        }
        return lastResult
    }

    @discardableResult
    func cancelAllInteractions() -> TerminalExternalIngressResult? {
        let result = cancelPointerInteractions()
        resetPreciseScrollState()
        return result
    }

    @discardableResult
    func scrollWheel(
        _ event: NSEvent,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        if event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.cancelled) {
            resetPreciseScrollState()
            return nil
        }

        let x = finite(Double(event.scrollingDeltaX))
        let y = finite(Double(event.scrollingDeltaY))
        if runtime.snapshot.mouseTracking {
            resetPreciseScrollState()
            return enqueueTrackedWheel(x: x, y: y, event: event, in: view)
        }

        if !event.hasPreciseScrollingDeltas {
            resetPreciseScrollState()
            guard y != 0 else { return nil }
            let magnitude = min(
                Double(TerminalFrontendInteractionView.maximumCommandCount),
                abs(y).rounded(.awayFromZero)
            )
            let lineCount = Int64(magnitude)
            let amount = y > 0 ? -lineCount : lineCount
            return runtime.enqueue(.scroll(operation: .lines, amount: amount))
        }

        return enqueuePreciseScroll(y: y, event: event)
    }

    @discardableResult
    func performSelection(
        _ operation: TerminalExternalSelectionOperation
    ) -> TerminalExternalIngressResult {
        runtime.enqueue(.selection(operation))
    }

    @discardableResult
    func performCopyMode(
        _ operation: TerminalExternalCopyModeOperation,
        adjustment: TerminalExternalCopyModeAdjustment?,
        count: UInt32
    ) -> TerminalExternalIngressResult {
        let boundedCount = min(
            max(count, 1),
            TerminalFrontendInteractionView.maximumCommandCount
        )
        return runtime.enqueue(.copyMode(
            operation: operation,
            adjustment: operation == .adjust ? adjustment : nil,
            count: boundedCount
        ))
    }

    @discardableResult
    func performSearch(
        _ operation: TerminalExternalSearchOperation,
        query: String?
    ) -> TerminalExternalIngressResult {
        let retainedQuery: String?
        switch operation {
        case .start, .update:
            retainedQuery = query.map(boundedSearchQuery)
        case .next, .previous, .end:
            retainedQuery = nil
        }
        return runtime.enqueue(.search(operation: operation, query: retainedQuery))
    }

    @discardableResult
    func performScroll(
        _ operation: TerminalExternalScrollOperation,
        amount: Int64?
    ) -> TerminalExternalIngressResult {
        let retainedAmount: Int64?
        switch operation {
        case .lines, .pages:
            let ceiling = Int64(TerminalFrontendInteractionView.maximumCommandCount)
            retainedAmount = amount.map { min(max($0, -ceiling), ceiling) }
        case .top, .bottom:
            retainedAmount = nil
        }
        return runtime.enqueue(.scroll(operation: operation, amount: retainedAmount))
    }

    func copySelectionToClipboard() async -> Bool {
        guard let selection = await runtime.readSelection(),
              !Task.isCancelled,
              !selection.text.isEmpty
        else { return false }
        return clipboardWriter.writeTerminalText(selection.text)
    }

    var hasCopyableSelection: Bool {
        if let selection = runtime.snapshot.selection, !selection.text.isEmpty {
            return true
        }
        return runtime.snapshot.accessibility?.selections.contains {
            !$0.text.isEmpty
        } == true
    }

    var hasPasteboardText: Bool {
        clipboardReader.hasTerminalText
    }

    @discardableResult
    func pasteClipboardText() -> TerminalExternalIngressResult? {
        guard let text = clipboardReader.readTerminalText(), !text.isEmpty else {
            return nil
        }
        return runtime.enqueue(.input(.text(TerminalExternalTextInput(
            text: text,
            kind: .paste
        ))))
    }

    func enableTerminalAccessibility() {
        runtime.enableAccessibility()
    }

    func disableTerminalAccessibility() {
        runtime.disableAccessibility()
    }

    func terminalAccessibilitySnapshots()
        -> AsyncStream<TerminalAccessibilitySnapshot> {
        runtime.accessibilitySnapshots()
    }

    func activateTerminalAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        await runtime.activateAccessibilityLink(link, snapshot: snapshot)
    }

    private func enqueueTrackedWheel(
        x: Double,
        y: Double,
        event: NSEvent,
        in view: NSView
    ) -> TerminalExternalIngressResult? {
        let vertical = abs(y) >= abs(x)
        let rawDelta = vertical ? y : x
        guard rawDelta != 0 else { return nil }
        let button: TerminalExternalMouseButton
        if vertical {
            button = rawDelta > 0 ? .wheelUp : .wheelDown
        } else {
            button = rawDelta > 0 ? .wheelLeft : .wheelRight
        }

        var sample = pointerSample(event, in: view)
        sample.clickCount = 1
        lastPointerSample = sample
        let boundedMagnitude = min(
            Double(Self.maximumWheelEventsPerAppKitEvent),
            abs(rawDelta).rounded(.up)
        )
        let count = max(1, Int(boundedMagnitude))
        var lastResult: TerminalExternalIngressResult?
        for _ in 0 ..< count {
            let result = enqueueMouse(
                action: .press,
                button: button,
                sample: sample,
                anyButtonPressed: true
            )
            lastResult = result
            if !result.accepted { break }
        }
        return lastResult
    }

    private func enqueuePreciseScroll(
        y: Double,
        event: NSEvent
    ) -> TerminalExternalIngressResult? {
        if event.phase.contains(.began) {
            resetPreciseScrollState()
        }
        if event.momentumPhase.contains(.began) {
            if !preservesRemainderForMomentum {
                preciseVerticalRemainderPoints = 0
            }
            preservesRemainderForMomentum = false
        }

        preciseVerticalRemainderPoints = finite(
            preciseVerticalRemainderPoints + y
        )
        let physicalEnded = event.phase.contains(.ended)
        let momentumMayBegin = event.momentumPhase.contains(.mayBegin)
        let momentumEnded = event.momentumPhase.contains(.ended)
        let standalone = event.phase.isEmpty && event.momentumPhase.isEmpty
        if physicalEnded && momentumMayBegin {
            preservesRemainderForMomentum = true
        }
        let terminalEvent = momentumEnded
            || standalone
            || (physicalEnded && !momentumMayBegin)

        let cellHeight = cellHeightPoints()
        let rawRows = preciseVerticalRemainderPoints / cellHeight
        let rows: Int64
        if terminalEvent {
            let magnitude = min(
                Double(TerminalFrontendInteractionView.maximumCommandCount),
                abs(rawRows).rounded(.awayFromZero)
            )
            rows = rawRows < 0 ? -Int64(magnitude) : Int64(magnitude)
        } else {
            let bounded = min(
                max(
                    rawRows,
                    -Double(TerminalFrontendInteractionView.maximumCommandCount)
                ),
                Double(TerminalFrontendInteractionView.maximumCommandCount)
            )
            rows = Int64(bounded.rounded(.towardZero))
        }

        if terminalEvent {
            resetPreciseScrollState()
        } else if rows != 0 {
            preciseVerticalRemainderPoints -= Double(rows) * cellHeight
        }
        guard rows != 0 else { return nil }
        return runtime.enqueue(.scroll(operation: .lines, amount: -rows))
    }

    private func enqueueMouse(
        action: TerminalExternalMouseAction,
        button: TerminalExternalMouseButton?,
        sample: PointerSample,
        anyButtonPressed: Bool
    ) -> TerminalExternalIngressResult {
        runtime.enqueue(.mouse(TerminalExternalMouseEvent(
            action: action,
            button: button,
            modifiers: sample.modifiers,
            xPixels: sample.xPixels,
            yPixels: sample.yPixels,
            anyButtonPressed: anyButtonPressed,
            clickCount: sample.clickCount
        )))
    }

    private func pointerSample(_ event: NSEvent, in view: NSView) -> PointerSample {
        let point = view.convert(event.locationInWindow, from: nil)
        let candidateScale: Double
        if let snapshotScale = runtime.snapshot.cellMetrics?.backingScale {
            candidateScale = snapshotScale
        } else if let window = view.window {
            candidateScale = Double(window.backingScaleFactor)
        } else if let layer = view.layer {
            candidateScale = Double(layer.contentsScale)
        } else {
            candidateScale = 1
        }
        let scale = candidateScale.isFinite ? max(candidateScale, 1) : 1
        let x = finite(Double(point.x - view.bounds.minX) * scale)
        let y = finite(Double(view.bounds.maxY - point.y) * scale)
        return PointerSample(
            xPixels: x,
            yPixels: y,
            modifiers: translator.keyModifiers(from: event.modifierFlags),
            clickCount: boundedClickCount(event)
        )
    }

    private func boundedClickCount(_ event: NSEvent) -> UInt32 {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return UInt32(clamping: min(max(event.clickCount, 1), 3))
        default:
            return 1
        }
    }

    private func buttonBit(_ button: TerminalExternalMouseButton) -> UInt8 {
        switch button {
        case .left: return 1 << 0
        case .right: return 1 << 1
        case .middle: return 1 << 2
        case .wheelUp, .wheelDown, .wheelLeft, .wheelRight: return 0
        }
    }

    private func cellHeightPoints() -> Double {
        guard let metrics = runtime.snapshot.cellMetrics,
              metrics.cellHeightPixels > 0
        else { return 1 }
        let scale = metrics.backingScale.isFinite
            ? max(metrics.backingScale, 1)
            : 1
        return max(Double(metrics.cellHeightPixels) / scale, 1)
    }

    private func boundedSearchQuery(_ query: String) -> String {
        var result = ""
        result.reserveCapacity(256)
        var byteCount = 0
        for scalar in query.unicodeScalars {
            let scalarByteCount: Int
            switch scalar.value {
            case ...0x7F: scalarByteCount = 1
            case ...0x7FF: scalarByteCount = 2
            case ...0xFFFF: scalarByteCount = 3
            default: scalarByteCount = 4
            }
            guard byteCount + scalarByteCount
                <= TerminalFrontendInteractionView.maximumSearchQueryUTF8Length
            else { break }
            result.unicodeScalars.append(scalar)
            byteCount += scalarByteCount
        }
        return result
    }

    private func resetPreciseScrollState() {
        preciseVerticalRemainderPoints = 0
        preservesRemainderForMomentum = false
    }

    private func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

@MainActor
private struct PointerSample {
    var xPixels: Double
    var yPixels: Double
    var modifiers: TerminalExternalKeyModifiers
    var clickCount: UInt32

    static let zero = Self(
        xPixels: 0,
        yPixels: 0,
        modifiers: [],
        clickCount: 1
    )
}
