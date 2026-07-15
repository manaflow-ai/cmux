import Foundation
import SwiftUI

/// A tiny pixel pet that walks in place while a coding agent is working in a
/// workspace. Rendered in the sidebar row's status-glyph row, next to the pin
/// and media-activity indicators.
///
/// The view is a fixed size and animates entirely inside a `Canvas`, so it
/// never changes the row's layout or height while it toggles on and off. This
/// matters: the sidebar rows live in a `LazyVStack`, where an animated layout
/// change forces a per-frame re-measure that pegs the main thread (see the
/// perf notes around `TabItemView` in `ContentView.swift`). The pet only ever
/// animates within its own frame.
struct SidebarWorkingAgentIndicatorView: View {
    let species: PixelAgentPet.Species
    /// Roughly the point size of the sibling glyphs; the pet is scaled to sit
    /// on the same visual line.
    var pointSize: CGFloat = 11

    // Sprite grid: 8 cells wide (leading tail + body), 5 tall, plus one row of
    // headroom for the little hop.
    private static let cellsWide: CGFloat = 8
    private static let cellsTall: CGFloat = 5

    var body: some View {
        let cell = max(1, (pointSize / Self.cellsTall).rounded())
        let width = cell * Self.cellsWide
        let height = cell * (Self.cellsTall + 1)
        let color = species.color
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                // Walk in place: legs alternate, with an occasional light hop so
                // the row reads as "actively working" rather than merely idle.
                let step = Int(t * 6) % 2
                let hop: CGFloat = sin(t * 7) > 0.6 ? -cell : 0
                // Leading tail sits at col -1, so start the body one cell in.
                let x = cell
                let y = (size.height - Self.cellsTall * cell) + hop
                PixelAgentPet.draw(
                    in: &context,
                    x: x,
                    y: y,
                    cell: cell,
                    color: color,
                    step: step,
                    facingRight: true
                )
            }
        }
        .frame(width: width, height: height)
        // The tooltip / accessibility label live on the parent row glyph.
        .accessibilityHidden(true)
    }
}
