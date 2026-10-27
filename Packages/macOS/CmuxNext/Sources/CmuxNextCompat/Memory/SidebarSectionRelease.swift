/// The app's one discard planner of sidebar sections (`ContentKind.sidebarSection`, p07-memory.md section 3.C,
/// task 100): each ``SidebarSectionRelease`` reports its shows and hides here, and the planner saves and drops a
/// hidden section when it is due. `SidebarSectionDiscards` (CmuxNextHibernation) is the one conformer, over the
/// `ContentDiscardScheduler` every other kind of content goes through.
@MainActor
public protocol SidebarSectionPlanner: AnyObject {
    /// `section`'s view exists and does not show: its hidden time starts now.
    func sectionDidHide(_ section: SidebarSectionRelease)
    /// `section`'s view shows: it is not due.
    func sectionDidShow(_ section: SidebarSectionRelease)
    /// `section`'s owner went: the planner forgets it.
    func sectionDidEnd(_ section: SidebarSectionRelease)
}

/// One section view's side of the sidebar section discard (`ContentKind.sidebarSection`): a right sidebar section or
/// a docked Home view, made once per window and kept while another one shows. Chrome discards a background tab and
/// keeps its navigation entry's scroll and form state (content/public/browser/navigation_entry.h); a hidden section
/// goes the same way: the owner saves a view-state record (scroll, open rows, query) in ``prepare()``, the view goes
/// in ``releaseNow()``, and the next show makes it again from that record. The shown section never goes.
///
/// It decides nothing on its own: the owner reports ``didMake()``, ``didShow()`` and ``didHide()``, and the app's
/// one planner (``SidebarSectionPlanner``) says when hidden content goes.
@MainActor
public final class SidebarSectionRelease {
    /// What the section is (`rightSidebar.files`, `homeDock.channels`), the start of its ``key``.
    public let owner: String
    /// Whether the section's view exists now.
    public private(set) var isHolding = false
    /// Whether the section's view shows now.
    public private(set) var isShown = false
    /// The releases done so far.
    public private(set) var releases = 0

    private let planner: any SidebarSectionPlanner
    private let save: @MainActor () async -> Void
    private let drop: @MainActor () -> Void
    private let holdsInput: @MainActor () -> Bool
    /// The shows so far: a save that a show interrupted is stale, even when the view hid again since.
    private var shows = 0

    /// - Parameters:
    ///   - owner: What the section is.
    ///   - planner: The App's one sidebar section planner.
    ///   - save: Saves the section's view-state record; runs before every release.
    ///   - drop: Lets the section's view go; called only while it is held and hidden.
    ///   - holdsUnsavedInput: The view holds input its record does not keep (a draft, a rename being typed).
    public init(owner: String, planner: any SidebarSectionPlanner, save: @escaping @MainActor () async -> Void,
                drop: @escaping @MainActor () -> Void, holdsUnsavedInput: @escaping @MainActor () -> Bool = { false }) {
        self.owner = owner
        self.planner = planner
        self.save = save
        self.drop = drop
        holdsInput = holdsUnsavedInput
    }

    /// The view holds input its record does not keep: it stays at any pressure (p07-memory.md, the lead rule).
    public var holdsUnsavedInput: Bool { isHolding && holdsInput() }

    /// The planner's name for this section: its owner and its identity, unique while it lives.
    public var key: String { "\(owner)#\(UInt(bitPattern: ObjectIdentifier(self).hashValue))" }

    /// The view was made; a hidden one starts its hidden time now.
    public func didMake() {
        guard !isHolding else { return }
        isHolding = true
        if !isShown { planner.sectionDidHide(self) }
    }

    /// The view shows: it is not due.
    public func didShow() {
        isShown = true
        shows += 1
        planner.sectionDidShow(self)
    }

    /// The view stopped showing: its hidden time starts.
    public func didHide() {
        guard isShown else { return }
        isShown = false
        if isHolding { planner.sectionDidHide(self) }
    }

    /// The planner's first step: the owner saves the view-state record. False when the view showed or went
    /// meanwhile, or holds unsaved input (before the save or after it).
    public func prepare() async -> Bool {
        guard isHolding, !isShown, !holdsInput() else { return false }
        let began = shows
        await save()
        return shows == began && isHolding && !isShown && !holdsInput()
    }

    /// The planner's call: drops a held, hidden view. False, and nothing goes, otherwise.
    @discardableResult
    public func releaseNow() -> Bool {
        guard isHolding, !isShown, !holdsInput() else { return false }
        drop()
        isHolding = false
        releases += 1
        return true
    }

    /// The owner goes: the planner forgets it.
    public func cancel() {
        isHolding = false
        planner.sectionDidEnd(self)
    }
}
