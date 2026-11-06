/// What a drag's base layout and drop rules are made from (`SidebarListView.dragBase`): the model's rows (any write of
/// them moves `contentRevision`), the row metrics and the layout options. While it is unchanged a drag move reuses both.
nonisolated struct SidebarDragBaseKey: Equatable {
    var content: UInt64
    var metrics: SidebarLayoutMetrics
    var options: SidebarLayoutOptions
    var ungroupedFirst: Bool
}
