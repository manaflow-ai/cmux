import CoreGraphics

/// A held group drag's state (`SidebarListDrag.group`): the base frozen at lift, the plan over it, the drop each
/// slot makes and the slot the card stands in now. The list draws `layout` and nothing else while it is held.
struct SidebarGroupDrag {
    /// What a drop in one slot sends: the list position (the model's reorder) and the document's move.
    struct Drop: Equatable {
        var position: DropPosition
        /// The document's move; nil when the list has no document (the model's reorder takes the position).
        var doc: SidebarDocTarget?
    }

    /// The list without the dragged group, laid out once at lift (or again when the model changes under the drag).
    let base: SidebarLayout
    let plan: SidebarGroupDragPlan
    /// Per slot (0 through the base's block count): the drop there, nil where none is accepted.
    let drops: [Drop?]
    /// The list structure (`SidebarModel.sectionsRevision`) the base was laid out for.
    let revision: UInt64
    /// The slot the card stands in now.
    var slot: Int

    /// The list as drawn now.
    var layout: SidebarLayout { plan.layout(base, slot: slot) }
}
