import AppKit
public import CmuxStatusBar
public import SwiftUI

/// One line of `statusBar.command` output: colored runs in a monospaced font,
/// with each OSC 8 link a click target.
public struct StatusBarLine: View {
    private let segments: [StatusBarSegment]
    private let fontSize: CGFloat
    private let alignment: Alignment
    private let openLink: @MainActor (String) -> Void

    /// Creates a line. `alignment` places it when it fits; `openLink` gets the
    /// target of a clicked link.
    public init(
        segments: [StatusBarSegment],
        fontSize: CGFloat,
        alignment: Alignment,
        openLink: @escaping @MainActor (String) -> Void
    ) {
        self.segments = segments
        self.fontSize = fontSize
        self.alignment = alignment
        self.openLink = openLink
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            line.frame(maxWidth: .infinity, alignment: alignment)
            // Wider than the window: keep the start in view and cut the end.
            line.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var line: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let label = Text(Self.attributed(segment.runs, size: fontSize))
                if let link = segment.link {
                    Self.linkPointer(label.onTapGesture { openLink(link) })
                } else {
                    label
                }
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private static func linkPointer(_ label: some View) -> some View {
        if #available(macOS 15, *) {
            label.pointerStyle(.link)
        } else {
            label
        }
    }

    private static func attributed(_ runs: [StatusBarRun], size: CGFloat) -> AttributedString {
        var output = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let color = run.color.map(nsColor) {
                piece.foregroundColor = Color(nsColor: run.dim ? color.withAlphaComponent(0.6) : color)
            } else if run.dim {
                piece.foregroundColor = .secondary
            }
            if run.bold { piece.font = .system(size: size, weight: .semibold, design: .monospaced) }
            output.append(piece)
        }
        return output
    }

    private static func nsColor(_ color: StatusBarRun.Color) -> NSColor {
        switch color {
        case .palette(let index):
            return ansiPalette[min(max(index, 0), ansiPalette.count - 1)]
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    private static let ansiPalette: [NSColor] = [
        .black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .lightGray,
        .darkGray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .white,
    ]
}
