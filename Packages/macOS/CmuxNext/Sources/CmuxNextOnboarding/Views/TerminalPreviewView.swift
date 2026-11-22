import AppKit
import CmuxNextDesign

/// A terminal in the chosen theme: its background, foreground and ANSI
/// colors on a few lines of sample output, in the system monospaced font.
final class TerminalPreviewView: NSView {
    var input: ThemeInput = .ghosttyDefault { didSet { if input != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = OnboardingMetrics.previewCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(OnboardingStrings.previewLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        input.background.nsColor.setFill()
        bounds.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var y: CGFloat = 16
        for line in Self.sample {
            let text = NSMutableAttributedString()
            for (piece, color) in line {
                let rgb = color.flatMap { input.palette.indices.contains($0) ? input.palette[$0] : nil } ?? input.foreground
                text.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: rgb.nsColor]))
            }
            text.draw(at: NSPoint(x: 16, y: y))
            y += 20
        }
    }

    // (text, ANSI palette index or nil for the foreground).
    static let sample: [[(String, Int?)]] = [
        [("~/cmux", 4), (" main", 5), (" ❯ ", 2), ("git status", nil)],
        [("modified: ", 1), ("Sources/App.swift", nil)],
        [("~/cmux", 4), (" ❯ ", 2), ("swift test", nil)],
        [("✔ ", 2), ("142 tests passed", nil)],
        [("~/cmux", 4), (" ❯ ", 2), ("claude", 3)],
    ]
}
