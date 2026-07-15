import CmuxMobileShell
import SwiftUI

/// A lightweight Canvas renderer for strip, card, and miniature terminal previews.
///
/// The view consumes one immutable ``PreviewGridSnapshot`` and owns no observable
/// store, making it safe below list snapshot boundaries. Text is monochrome with
/// default terminal colors; bold and dim attributes are retained when available.
public struct TerminalGridThumbnailView: View {
    private let snapshot: PreviewGridSnapshot

    /// Creates a thumbnail for one immutable terminal grid snapshot.
    /// - Parameter snapshot: The surface snapshot to render, or its skeleton state.
    public init(snapshot: PreviewGridSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        if snapshot.hasBaseline {
            thumbnailCanvas
        } else {
            skeleton
        }
    }

    private var thumbnailCanvas: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(TerminalPalette.background))
            let layout = TerminalGridThumbnailLayout(snapshot: snapshot)
            let cellHeight = size.height / CGFloat(max(1, layout.rows))
            let cellWidth = size.width / CGFloat(max(1, layout.columns))
            // Fit both axes so narrow pane miniatures keep explicit producer
            // columns instead of allowing font advances to drift into neighbors.
            let fontSize = max(0.5, min(cellHeight * 0.82, cellWidth / 0.6))
            for run in layout.runs(in: size) where !run.style.isInvisible {
                let text = Text(run.text)
                    .font(.system(
                        size: fontSize,
                        weight: run.style.isBold ? .bold : .regular,
                        design: .monospaced
                    ))
                    .foregroundStyle(TerminalPalette.foreground.opacity(run.style.isDim ? 0.55 : 1))
                context.draw(
                    text,
                    at: CGPoint(x: run.frame.minX, y: run.frame.minY),
                    anchor: .topLeading
                )
            }
        }
        .clipped()
        .background(TerminalPalette.background)
        .accessibilityHidden(true)
    }

    private var skeleton: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(TerminalPalette.background))
            let lineHeight = max(1, size.height * 0.06)
            let spacing = lineHeight * 1.8
            for index in 0..<5 {
                let width = size.width * (index.isMultiple(of: 2) ? 0.68 : 0.46)
                let rect = CGRect(
                    x: size.width * 0.08,
                    y: size.height * 0.16 + CGFloat(index) * spacing,
                    width: width,
                    height: lineHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: lineHeight / 2),
                    with: .color(TerminalPalette.foreground.opacity(0.16))
                )
            }
        }
        .background(TerminalPalette.background)
        .accessibilityHidden(true)
    }
}
