public import CmuxNextDesign
public import Foundation

/// What one workspace row draws (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE): the
/// one place that turns a workspace's facts and `sidebar.workspaceRow.*`
/// into row content. The layout sizes the row from it and the row view draws
/// only what it says, so no other code adds a line, a count or a badge.
///
/// The working-indicator slot: `showsWorking` is true while some tab has
/// agent work (an acpmux turn, a hook or OSC 7501 `working`:
/// `SidebarWorkspace.agentWorking`) and the `working` element is on. The
/// status glyph then draws the working dots (`StatusIndicatorState.working`);
/// a stronger state of the workspace (waiting, error) takes the one slot.
public nonisolated struct WorkspaceRowContent: Hashable, Sendable {
    /// Draw the user's icon (nil when the user set none or turned icons off).
    public var icon: WorkspaceIcon?
    /// The second line: the shown second-line elements in order, joined.
    public var detail: String?
    /// The tab count, when that element is on.
    public var tabCount: Int?
    /// The pull request / CI badge text, when that element is on.
    public var badge: String?
    /// The status glyph: attention states (waiting, error, success) always;
    /// busy or paused only for an agent turn with `working` on, or with
    /// `progress` on.
    public var activity: StatusIndicatorState
    /// The bar under the row, when `progress` is on.
    public var progress: SidebarProgress?
    /// The agent-working indicator slot (WORKING-AND-LOADING-INDICATORS).
    public var showsWorking: Bool

    public init(icon: WorkspaceIcon? = nil, detail: String? = nil, tabCount: Int? = nil, badge: String? = nil,
                activity: StatusIndicatorState = .idle, progress: SidebarProgress? = nil, showsWorking: Bool = false) {
        self.icon = icon
        self.detail = detail
        self.tabCount = tabCount
        self.badge = badge
        self.activity = activity
        self.progress = progress
        self.showsWorking = showsWorking
    }

    /// Separates second-line items.
    public static let separator = " · "

    /// The content of `ws`'s row under `preferences`; `now` decides whether
    /// the last activity shows a time (today) or a date.
    public init(_ ws: SidebarWorkspace, preferences: WorkspaceRowPreferences, now: Date = Date()) {
        let set = preferences.resolved(for: ws.rowKind)
        let items = set.secondLine.compactMap { Self.text(of: $0, in: ws, now: now) }
        let working = ws.agentWorking && set.shows(.working)
        self.init(
            icon: set.shows(.icon) ? ws.icon : nil,
            detail: items.isEmpty ? nil : items.joined(separator: Self.separator),
            tabCount: set.shows(.tabCount) ? ws.tabs.count : nil,
            badge: set.shows(.pullRequest) ? Self.nonEmpty(ws.pullRequest) : nil,
            activity: Self.activity(ws.activity, working: working, progress: set.shows(.progress)),
            progress: set.shows(.progress) ? ws.progress : nil,
            showsWorking: working
        )
    }

    static func activity(_ state: StatusIndicatorState, working: Bool, progress: Bool) -> StatusIndicatorState {
        switch state {
        case .idle, .waiting, .error, .success: state
        case .busy, .paused: working || progress ? state : .idle
        // Agent work (WORKING-AND-LOADING-INDICATORS) shows only with `working` on.
        case .working: working ? state : .idle
        }
    }

    static func text(of element: WorkspaceRowElement, in ws: SidebarWorkspace, now: Date) -> String? {
        switch element {
        case .directory: nonEmpty(ws.directory)
        case .branch: nonEmpty(ws.branch)
        case .process: nonEmpty(ws.process)
        case .agentStatus: nonEmpty(ws.status)
        case .ports: nonEmpty(ws.ports)
        case .lastActivity: ws.lastActivity.map { activityText($0, now: now) }
        case .icon, .tabCount, .pullRequest, .progress, .working: nil
        }
    }

    /// A time today, else a short date: a fixed label needs no timer.
    static func activityText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
