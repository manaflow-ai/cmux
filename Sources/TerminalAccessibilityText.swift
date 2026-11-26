import AppKit

/// The text a terminal surface shows to accessibility clients, plus the rules
/// for turning an accessibility write back into terminal input.
///
/// Dictation tools (Typeless, Wispr Flow, Superwhisper, Willow) read `AXValue`
/// before and after they insert, and treat an unchanged value as a failed
/// insertion. The value is a short-lived snapshot of the active screen so
/// repeated AX queries in one burst don't each copy the grid out of Ghostty.
@MainActor
final class TerminalAccessibilityText {
    /// How long one snapshot answers AX queries before it is read again.
    static let snapshotLifetime: TimeInterval = 0.5
    /// Delay before announcing a value change after an AX insertion, so the
    /// shell or agent has usually echoed the text by the time clients re-read.
    static let valueChangedDelay: TimeInterval = 0.15

    /// How long a value handed to an AX client remains eligible for edit
    /// detection after it was last vended.
    static let vendedValueHistoryLifetime: TimeInterval = 30
    /// The total UTF-8 size of values retained for edit detection.
    static let vendedValueHistoryByteLimit = 4 * 1024 * 1024

    private struct VendedValue {
        let value: String
        var lastVendedAt: TimeInterval
        let byteCount: Int
    }

    private var snapshot: String?
    private var snapshotCapturedAt: TimeInterval = 0
    /// Values recently handed to AX clients, newest last. A client that edits
    /// `AXValue` sends back one of these with its insertion spliced in.
    var vendedValues: [String] {
        vendedValueHistory.map(\.value)
    }
    private var vendedValueHistory: [VendedValue] = []
    private weak var valueChangedElement: NSView?
    private var valueChangedTimer: Timer?
    private var valueChangedBaseline: String?
    private var valueChangedCompletion: (() -> Void)?

    nonisolated init() {}

    /// Returns the cached snapshot, reading a fresh one when it has expired.
    func value(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        read: () -> String?
    ) -> String {
        let value: String
        if let snapshot, now - snapshotCapturedAt < Self.snapshotLifetime {
            value = snapshot
        } else {
            value = read() ?? ""
            snapshot = value
            snapshotCapturedAt = now
        }
        recordVendedValue(value, at: now)
        return value
    }

    /// Drops the snapshot so the next AX query reads the terminal again.
    func invalidate() {
        snapshot = nil
    }

    /// Waits for the terminal's next screen update before announcing an AX
    /// insertion. The timer is only an acknowledgement fallback for input
    /// that produces no visible screen echo (password prompts and full-screen
    /// applications, for example).
    func scheduleValueChanged(for element: NSView, onComplete: (() -> Void)? = nil) {
        valueChangedTimer?.invalidate()
        valueChangedElement = element
        valueChangedBaseline = snapshot ?? vendedValueHistory.last?.value
        valueChangedCompletion = onComplete
        let timer = Timer(timeInterval: Self.valueChangedDelay, repeats: false) { [weak self] timer in
            // This timer is registered only on RunLoop.main below.
            MainActor.assumeIsolated {
                guard let self, self.valueChangedTimer === timer else { return }
                self.valueChangedTimer = nil
                self.finishValueChangedNotification()
            }
        }
        valueChangedTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Completes a pending AX notification after a rendered frame has made the
    /// terminal's screen text authoritative. Returns whether the pending
    /// notification was posted.
    @discardableResult
    func screenDidChange(read: () -> String?) -> Bool {
        guard valueChangedTimer != nil else { return false }
        let current = read() ?? ""
        guard let baseline = valueChangedBaseline, current != baseline else { return false }
        valueChangedTimer?.invalidate()
        valueChangedTimer = nil
        finishValueChangedNotification()
        return true
    }

    private func finishValueChangedNotification() {
        invalidate()
        let element = valueChangedElement
        let completion = valueChangedCompletion
        valueChangedElement = nil
        valueChangedBaseline = nil
        valueChangedCompletion = nil
        if let element {
            NSAccessibility.post(element: element, notification: .valueChanged)
        }
        completion?()
    }

    /// Returns the text an AX client meant to insert when it sets the whole value.
    ///
    /// Some clients write `AXValue` as a value they read with their text
    /// spliced in. Typing that back would paste the screen into the shell,
    /// so when `newValue` is an edit of a recently vended value, only the
    /// edited middle is returned. Anything else is taken literally, which is
    /// how clients that set just the dictated text have always worked.
    /// Vended values remain eligible for 30 seconds since their last AX read,
    /// including cached reads. History is capped at 4 MiB of UTF-8 text,
    /// evicting the least recently vended values first when it exceeds the cap.
    /// A single value larger than the cap is not retained.
    func insertedText(
        settingValue newValue: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> String {
        pruneVendedValues(at: now)
        // An exact read anywhere in history beats a partial match against a
        // newer screen, which would paste the older screen's differing tail.
        for allowsPartialMatch in [false, true] {
            for vended in vendedValueHistory.reversed() {
                if let inserted = Self.insertedText(
                    settingValue: newValue,
                    over: vended.value,
                    allowsPartialMatch: allowsPartialMatch
                ) {
                    return inserted
                }
            }
        }
        return newValue
    }

    private func recordVendedValue(_ value: String, at now: TimeInterval) {
        pruneVendedValues(at: now)
        guard !value.isEmpty else { return }
        if vendedValueHistory.last?.value == value {
            vendedValueHistory[vendedValueHistory.count - 1].lastVendedAt = now
            return
        }
        let byteCount = value.utf8.count
        guard byteCount <= Self.vendedValueHistoryByteLimit else { return }
        vendedValueHistory.removeAll { $0.value == value }
        vendedValueHistory.append(VendedValue(value: value, lastVendedAt: now, byteCount: byteCount))
        var totalBytes = vendedValueHistory.reduce(0) { $0 + $1.byteCount }
        while totalBytes > Self.vendedValueHistoryByteLimit, !vendedValueHistory.isEmpty {
            totalBytes -= vendedValueHistory.removeFirst().byteCount
        }
    }

    private func pruneVendedValues(at now: TimeInterval) {
        vendedValueHistory.removeAll { now - $0.lastVendedAt >= Self.vendedValueHistoryLifetime }
    }

    /// The edited middle of `newValue` when it keeps `currentValue` around one
    /// edit, or `nil` when it isn't an edit of `currentValue`.
    ///
    /// A pure insertion keeps all of `currentValue`. A longer value may also
    /// have lost a selection the client replaced, so it counts when most of
    /// it survives. Short values need a pure insertion, so a literal that
    /// happens to end like a two-character prompt isn't trimmed. With
    /// `allowsPartialMatch` false, only a pure insertion counts.
    static func insertedText(
        settingValue newValue: String,
        over currentValue: String,
        allowsPartialMatch: Bool = true
    ) -> String? {
        let old = Array(currentValue.unicodeScalars)
        guard !old.isEmpty else { return nil }
        let new = Array(newValue.unicodeScalars)
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let kept = prefix + suffix
        guard kept == old.count || (allowsPartialMatch && old.count >= 64 && kept >= old.count / 2) else {
            return nil
        }
        var inserted = String.UnicodeScalarView()
        inserted.append(contentsOf: new[prefix..<(new.count - suffix)])
        return String(inserted)
    }

    /// Splits committed text into the part to insert and a trailing run of
    /// line breaks that the client sent as a submit.
    static func splitTrailingLineBreaks(_ text: String) -> (body: String, lineBreaks: String) {
        let scalars = Array(text.unicodeScalars)
        var end = scalars.count
        while end > 0, scalars[end - 1] == "\n" || scalars[end - 1] == "\r" {
            end -= 1
        }
        var body = String.UnicodeScalarView()
        body.append(contentsOf: scalars[..<end])
        var lineBreaks = String.UnicodeScalarView()
        lineBreaks.append(contentsOf: scalars[end...])
        return (String(body), String(lineBreaks))
    }

    /// Whether `text` contains a line break.
    static func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// Removes control characters other than tab and line breaks from
    /// multi-line dictation before it is pasted. Dictated text never needs
    /// them, and an ESC inside a bracketed paste could end it early.
    static func pastePayload(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                kept.append(scalar)
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                continue
            default:
                kept.append(scalar)
            }
        }
        return String(kept)
    }
}
