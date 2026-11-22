import Foundation

/// How far the workspace's agent chat is through its task list (acpmux's `taskList`, kept across
/// the chat's turns: its harness's plan, else what its agent or Chief keeps): the row's plan line or
/// hairline (`SidebarTaskProgressLook`) and the hover card's done, now and next lines. Set only while
/// steps are left (`SidebarLaneStatus`); a finished list draws nothing, as the row's unread dot
/// already says the chat finished.
public nonisolated struct SidebarTaskProgress: Hashable, Sendable {
    /// Steps completed, at most `total`.
    public var done: Int
    /// Every step; more than zero.
    public var total: Int
    /// The step in progress; nil when none is.
    public var current: String?
    /// The next step still pending; nil when none is left.
    public var next: String?

    public init(done: Int, total: Int, current: String? = nil, next: String? = nil) {
        self.total = max(total, 1)
        self.done = min(max(done, 0), self.total)
        self.current = current
        self.next = next
    }

    /// The 1-based number of the step in progress (`current`), else of the next one left: what "2 of 5" counts.
    public var stepNumber: Int { min(done + 1, total) }
    /// The share of steps done, 0...1.
    public var fraction: Double { Double(done) / Double(total) }
}

/// How a workspace row shows its agent chat's task list (Leo 2026-11-22: "if we ever EVER FUCKING WANT SOME BULLSHIT
/// LIKE THIS, WE FUCKING DO IT PROPERLY. SO GO DO IT PROPERLY."). The Nov 20 look put a "0/1" count on the name's line,
/// which cut the title to one word ("limit 0/1 •"); no look here takes any room from the title. Picked from
/// `AASidebarTaskPlanGalleryTests` (``shipped``); the hover card says done, now and next under every look.
public nonisolated enum SidebarTaskProgressLook: String, CaseIterable, Hashable, Sendable {
    /// The row draws nothing; the hover card alone says it.
    case hidden
    /// A row that already has a second line reads the step in progress there, with a muted "2 of 5" at its end. A
    /// one-line row draws nothing, so rows never grow and shrink as plans come and go.
    case stepLine
    /// A hairline at the row's foot, the share of steps done, while the chat works and its list has 2 or more steps.
    case hairline
    /// The hairline in one segment per step (done, in progress, left) up to ``segmentLimit`` steps, continuous past it.
    case segments
    /// ``stepLine`` on a two-line row, ``segments`` on every row while it works.
    case stepLineAndSegments

    /// The look the sidebar ships.
    public static let shipped = SidebarTaskProgressLook.stepLineAndSegments
    /// Above this many steps the hairline draws as one continuous fill: past it a segment is a few pixels wide.
    public static let segmentLimit = 12

    /// Draws the step in progress on a row's second line.
    public var drawsStepLine: Bool { self == .stepLine || self == .stepLineAndSegments }
    /// The hairline this look draws, nil for none.
    public var bar: SidebarTaskBar.Style? {
        switch self {
        case .hidden, .stepLine: nil
        case .hairline: .continuous
        case .segments, .stepLineAndSegments: .segments
        }
    }
}

/// The hairline a row draws for its task list (`SidebarTaskProgressLook.bar`).
public nonisolated struct SidebarTaskBar: Hashable, Sendable {
    public enum Style: Hashable, Sendable { case continuous, segments }
    public var style: Style
    public var progress: SidebarTaskProgress

    /// One segment per step, or one continuous fill past ``SidebarTaskProgressLook/segmentLimit`` steps.
    public var segmented: Bool { style == .segments && progress.total <= SidebarTaskProgressLook.segmentLimit }
}
