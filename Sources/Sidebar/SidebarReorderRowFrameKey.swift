import SwiftUI

/// Collects the live frames of the workspace sidebar rows (and group headers),
/// keyed by represented workspace id, in the list's `"sidebarReorderList"`
/// coordinate space.
///
/// The gesture-driven reorder reads these via `.onPreferenceChange` to hit-test
/// the drag cursor against the rows. Resolving concrete `CGRect`s (rather than
/// `Anchor<CGRect>`) lets the value flow straight into `SidebarDragState`'s
/// non-observed geometry without a `GeometryProxy`, so the push never happens
/// inside a view-body computation.
struct SidebarReorderRowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Reports this row's frame in the reorder list coordinate space under
    /// `workspaceId`.
    func sidebarReorderRowFrame(_ workspaceId: UUID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarReorderRowFrameKey.self,
                    value: [workspaceId: proxy.frame(in: .named(SidebarReorderListCoordinateSpace.name))]
                )
            }
        )
    }
}

/// The named coordinate space the reorder gesture and row frames share, so the
/// gesture location and the measured row frames are guaranteed to align.
enum SidebarReorderListCoordinateSpace {
    static let name = "sidebarReorderList"
}
