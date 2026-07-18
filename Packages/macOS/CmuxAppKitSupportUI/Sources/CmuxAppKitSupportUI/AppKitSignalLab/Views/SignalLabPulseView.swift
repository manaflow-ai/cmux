#if canImport(AppKit)

import AppKit

@MainActor
final class SignalLabPulseView: NSView {
    var samples: [Double] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !samples.isEmpty else { return }

        let gap: CGFloat = 5
        let availableWidth = bounds.width - gap * CGFloat(samples.count - 1)
        let barWidth = max(3, availableWidth / CGFloat(samples.count))
        let color = NSColor.controlAccentColor

        for (index, sample) in samples.enumerated() {
            let clampedSample = max(0.08, min(1, sample))
            let height = bounds.height * clampedSample
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: bounds.height - height,
                width: barWidth,
                height: height
            )
            color.withAlphaComponent(0.35 + clampedSample * 0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }
}

#endif
