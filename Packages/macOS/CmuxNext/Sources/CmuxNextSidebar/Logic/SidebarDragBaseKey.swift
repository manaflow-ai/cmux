import CoreGraphics

/// What a drag's base layout and drop rules are made from (`SidebarListView.dragBase`), in values a move reads in
/// constant time: the model's rows (any write of them moves `contentRevision`), the list's reloads (every change of
/// the layout options the list draws runs one, `SidebarListView.reloads`), its width (block heights), the row metrics
/// and the drop tunables the rules hold. While it is unchanged a drag move reuses both and builds no options.
nonisolated struct SidebarDragBaseKey: Equatable {
    var content: UInt64
    var reloads: UInt64
    var width: CGFloat
    var metrics: SidebarLayoutMetrics
    var ungroupedFirst: Bool
    /// The empty section whose drop zone shows (`SidebarListDrag.openZone`).
    var openZone: String?
    var drop = DropResolver.tunables
}
