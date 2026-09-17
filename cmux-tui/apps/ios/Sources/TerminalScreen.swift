import SwiftUI

/// Draws the daemon's terminal model.
///
/// The phone carries no VT parser: the daemon already resolved wrapping,
/// scroll regions, and character sets into styled runs, so this only has to
/// lay out a monospaced grid and paint the runs.
struct TerminalScreen: View {
    let snapshot: TerminalSnapshot?
    let fontSize: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let snapshot else { return }
            let font = Font.system(size: fontSize, design: .monospaced)
            let metrics = TerminalMetrics(fontSize: fontSize)

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(snapshot.defaultBg.swiftUI))

            for row in snapshot.rows {
                let y = CGFloat(row.row) * metrics.lineHeight
                var column = 0
                for run in row.runs {
                    let x = CGFloat(column) * metrics.advance
                    if let background = run.bg {
                        let width = CGFloat(run.text.count) * metrics.advance
                        context.fill(
                            Path(CGRect(x: x, y: y, width: width, height: metrics.lineHeight)),
                            with: .color(background.swiftUI))
                    }
                    var text = Text(run.text).font(font)
                    if run.isBold { text = text.bold() }
                    if run.isItalic { text = text.italic() }
                    context.draw(
                        text.foregroundColor((run.fg ?? snapshot.defaultFg).swiftUI),
                        at: CGPoint(x: x, y: y),
                        anchor: .topLeading)
                    column += run.text.count
                }
            }

            if snapshot.cursor.visible {
                let rect = CGRect(
                    x: CGFloat(snapshot.cursor.x) * metrics.advance,
                    y: CGFloat(snapshot.cursor.y) * metrics.lineHeight,
                    width: metrics.advance,
                    height: metrics.lineHeight)
                context.fill(Path(rect), with: .color(snapshot.defaultFg.swiftUI.opacity(0.65)))
            }
        }
        .background(snapshot?.defaultBg.swiftUI ?? .black)
    }
}

/// Monospaced cell geometry. The advance is measured once from the font rather
/// than guessed, so the grid the daemon renders and the grid drawn here agree
/// on where column N is.
struct TerminalMetrics {
    let advance: CGFloat
    let lineHeight: CGFloat

    init(fontSize: CGFloat) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        advance = "M".size(withAttributes: [.font: font]).width
        lineHeight = font.lineHeight
    }

    /// The largest grid that fits, which is what the remote PTY should be
    /// resized to. Anything larger and the daemon renders columns the phone
    /// cannot show.
    func grid(in size: CGSize) -> (cols: UInt16, rows: UInt16) {
        let cols = max(20, min(500, Int(size.width / advance)))
        let rows = max(5, min(200, Int(size.height / lineHeight)))
        return (UInt16(cols), UInt16(rows))
    }
}

extension TerminalSnapshot.Color {
    var swiftUI: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
