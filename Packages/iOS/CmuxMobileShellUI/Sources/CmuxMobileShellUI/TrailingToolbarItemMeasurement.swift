import SwiftUI

/// One trailing toolbar item's rendered content geometry, captured together
/// with the pane width it was measured at so a stale value from before a
/// rotation or split-width change is never mixed into current-width math.
struct TrailingToolbarItemGeometry: Equatable {
    /// Rendered content width (inside the glass capsule chrome).
    var width: CGFloat
    /// Leading edge of the content in the global space, used to derive the
    /// real title-to-trailing span.
    var globalMinX: CGFloat
    /// The pane width current when this measurement fired.
    var contentWidth: CGFloat
}

extension View {
    /// Reports this trailing toolbar item's rendered content geometry into the
    /// shared measurement dictionary.
    ///
    /// The leading title menu caps its width to the bar's remaining space so
    /// the trailing items are never squeezed into the overflow More menu.
    /// Deliberately no `onDisappear` cleanup: overflowing into More also
    /// removes the bar content, so clearing on disappear would release the
    /// reservation and make the collapse sticky. Callers that structurally
    /// remove an item clear its key from the condition that removed it.
    func measureTrailingToolbarItem(
        _ key: String,
        into geometry: Binding<[String: TrailingToolbarItemGeometry]>,
        contentWidth: @escaping @autoclosure () -> CGFloat
    ) -> some View {
        onGeometryChange(for: TrailingToolbarItemProbe.self) { proxy in
            TrailingToolbarItemProbe(
                width: proxy.size.width,
                globalMinX: proxy.frame(in: .global).minX
            )
        } action: { probe in
            geometry.wrappedValue[key] = TrailingToolbarItemGeometry(
                width: probe.width,
                globalMinX: probe.globalMinX,
                contentWidth: contentWidth()
            )
        }
    }
}

/// Equatable payload for `onGeometryChange`, which only re-fires when the
/// reduced value changes.
private struct TrailingToolbarItemProbe: Equatable {
    var width: CGFloat
    var globalMinX: CGFloat
}

/// The fitted title label's leading edge, captured with the pane width it was
/// measured at (same staleness contract as `TrailingToolbarItemGeometry`).
struct WorkspaceTitleLabelEdge: Equatable {
    var globalMinX: CGFloat
    var contentWidth: CGFloat
}
