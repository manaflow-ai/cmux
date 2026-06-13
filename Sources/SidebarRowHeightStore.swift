import CoreGraphics

/// Holds a sidebar row's measured height in a reference cell so the row's
/// `rowHeightProbe` can record geometry changes WITHOUT writing `@State`.
///
/// The drop delegates need the target row's pixel height to decide whether a
/// hovering drop lands in the row's top or bottom half (insert-before vs
/// insert-after). Previously each row kept that height in `@State`, written from
/// a background `GeometryReader` on appearance and on every height change — a
/// guaranteed `1 -> realHeight` write per appearance that forced a second full
/// body evaluation of the row inside the lazy placement pass, plus another eval
/// on each later change.
///
/// With a reference cell the probe mutates `height` in place (no invalidation),
/// and the drop delegate reads it LAZILY at drop time via `height`, so it always
/// sees the current measurement even though no body re-eval reconstructs the
/// delegate. Held by the row as plain `@State` (a stable reference, never
/// reassigned), so SwiftUI keeps the same instance across re-renders.
@MainActor
final class SidebarRowHeightStore {
    var height: CGFloat = 1

    init() {}
}
