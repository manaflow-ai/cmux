public import CoreGraphics

/// What a sidebar section showed when its view was let go (``SidebarSectionRelease``, feature
/// `memoryDiscardSidebarSections`): the next show builds the section again from it, as Chrome builds a
/// discarded tab again from its navigation entry's scroll and form state (content/public/browser/navigation_entry.h).
public struct SidebarSectionState: Equatable, Sendable {
    /// The list's visible origin.
    public var scroll: CGPoint?
    /// The text of its search field.
    public var query: String?
    /// What it had selected (a path, a result's place).
    public var selection: String?
    /// Its open rows (the Files tree's open folders), by path.
    public var expanded: [String]

    public init(scroll: CGPoint? = nil, query: String? = nil, selection: String? = nil, expanded: [String] = []) {
        self.scroll = scroll
        self.query = query
        self.selection = selection
        self.expanded = expanded
    }
}

/// A section view that saves and restores its own ``SidebarSectionState``. A section that is not one keeps only the
/// scroll of its first list.
@MainActor
public protocol SidebarSectionStateKeeping: AnyObject {
    /// What the section shows now.
    var sectionState: SidebarSectionState { get }
    /// Shows `state` in a section made again; called once, right after it was made.
    func restoreSectionState(_ state: SidebarSectionState)
    /// The section holds input ``sectionState`` does not keep (a name being typed in a row): it stays while hidden.
    var holdsUnsavedInput: Bool { get }
}

extension SidebarSectionStateKeeping {
    /// Its state keeps all it holds.
    public var holdsUnsavedInput: Bool { false }
}
