import SwiftUI

/// One trailing toolbar item's rendered content geometry.
///
/// Values are plain positions with no width epoch: the span consumer rejects
/// measurements that are implausible for the current pane width (a stale
/// wider-layout edge lands past the pane's end), and stale narrower-layout
/// values only under-size the title, which is safe. Fresh geometry re-fires
/// the probes because real positions change whenever the bar re-lays out.
struct TrailingToolbarItemGeometry: Equatable {
    /// Rendered content width (inside the glass capsule chrome).
    var width: CGFloat
    /// Leading edge of the content in the global space, used to derive the
    /// real title-to-trailing span.
    var globalMinX: CGFloat
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
        into geometry: Binding<[String: TrailingToolbarItemGeometry]>
    ) -> some View {
        onGeometryChange(for: TrailingToolbarItemGeometry.self) { proxy in
            TrailingToolbarItemGeometry(
                width: proxy.size.width,
                globalMinX: proxy.frame(in: .global).minX
            )
        } action: { probe in
            geometry.wrappedValue[key] = probe
        }
    }
}

