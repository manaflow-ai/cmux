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

    private var snapshot: String?
    private var snapshotCapturedAt: TimeInterval = 0
    /// The last value handed to an AX client. A client that edits `AXValue`
    /// sends back this text with its insertion spliced in.
    private(set) var lastVendedValue = ""
    private var valueChangedTimer: Timer?

    nonisolated init() {}

    /// Returns the cached snapshot, reading a fresh one when it has expired.
    func value(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        read: () -> String?
    ) -> String {
        if let snapshot, now - snapshotCapturedAt < Self.snapshotLifetime {
            lastVendedValue = snapshot
            return snapshot
        }
        let fresh = read() ?? ""
        snapshot = fresh
        snapshotCapturedAt = now
        lastVendedValue = fresh
        return fresh
    }

    /// Drops the snapshot so the next AX query reads the terminal again.
    func invalidate() {
        snapshot = nil
    }

    /// Posts one debounced `valueChanged` for `element` after an AX insertion.
    func scheduleValueChanged(for element: NSView) {
        valueChangedTimer?.invalidate()
        let timer = Timer(timeInterval: Self.valueChangedDelay, repeats: false) { [weak self, weak element] timer in
            // This timer is registered only on RunLoop.main below.
            MainActor.assumeIsolated {
                guard let self, self.valueChangedTimer === timer else { return }
                self.valueChangedTimer = nil
                self.invalidate()
                guard let element else { return }
                NSAccessibility.post(element: element, notification: .valueChanged)
            }
        }
        valueChangedTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Returns the text an AX client meant to insert when it sets the whole value.
    ///
    /// Some clients write `AXValue` as the value they last read with their
    /// text spliced in. Typing that back would paste the whole screen into the
    /// shell, so when `newValue` keeps most of `currentValue` around one edit,
    /// only the edited middle is returned. Anything else is taken literally,
    /// which is how clients that set just the dictated text have always worked.
    static func insertedText(settingValue newValue: String, over currentValue: String) -> String {
        let old = Array(currentValue.unicodeScalars)
        guard !old.isEmpty else { return newValue }
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
        guard prefix + suffix >= (old.count + 1) / 2 else { return newValue }
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
