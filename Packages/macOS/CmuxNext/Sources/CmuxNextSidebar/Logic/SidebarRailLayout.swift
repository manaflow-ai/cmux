import CmuxNextDesign
public import CoreGraphics

/// One mark on the sidebar rail (`sidebar.style` = rail,
/// plans/cmux-next/minimal-sidebar.md): a workspace, or a collapsed group
/// drawn as one mark.
public nonisolated struct SidebarRailMark: Hashable, Sendable {
    /// What the mark stands for (the Cmd-digit and click target).
    public enum Target: Hashable, Sendable {
        case workspace(WorkspaceID)
        case group(GroupID)
    }

    /// The state a mark shows, most urgent wins in a collapsed group.
    public enum State: Int, Hashable, Sendable, Comparable {
        case idle
        case working
        case unread

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var target: Target
    public var isSelected: Bool
    public var state: State

    public init(target: Target, isSelected: Bool, state: State) {
        self.target = target
        self.isSelected = isSelected
        self.state = state
    }

    /// A workspace's mark: unread first, then a working agent or activity.
    public init(workspace: SidebarWorkspace, isSelected: Bool) {
        let busy: Bool = if case .busy = workspace.activity { true } else { false }
        let state: State = workspace.unread.isUnread ? .unread : workspace.agentWorking || busy ? .working : .idle
        self.init(target: .workspace(workspace.id), isSelected: isSelected, state: state)
    }
}

/// Where each rail mark sits: one short tick per mark, top to bottom in
/// sidebar order, a larger gap between groups. When the marks do not fit,
/// every pitch shrinks in proportion (like a scrollbar's thumb), down to a
/// 1 pt tick; the rail never scrolls.
public nonisolated struct SidebarRailLayout: Hashable, Sendable {
    public struct Tick: Hashable, Sendable {
        public var mark: SidebarRailMark
        public var rect: CGRect
        /// The top of the tick's row (`row(of:railWidth:)`).
        public var rowY: CGFloat = 0
    }

    /// The geometry, in points. Defaults are the shipped design (variant A,
    /// "Hairline ticks", in plans/cmux-next/minimal-sidebar-gallery).
    public struct Metrics: Hashable, Sendable {
        public var railWidth: CGFloat = 6
        public var tickHeight: CGFloat = 2
        public var tickWidth: CGFloat = 4
        /// A selected tick spans the rail.
        public var selectedTickWidth: CGFloat = 6
        public var pitch: CGFloat = 6
        public var groupGap: CGFloat = 8

        public init() {}
    }

    public private(set) var ticks: [Tick] = []
    /// The share of the natural pitch the marks got (1 when they fit).
    public private(set) var scale: CGFloat = 1
    /// The distance between two ticks of a group now (the natural pitch times `scale`).
    public private(set) var pitch: CGFloat = 0

    /// - Parameters:
    ///   - groups: The marks in sidebar order, one array per group or loose run; empty groups are skipped.
    ///   - top: The first tick's top, in flipped coordinates (y grows down).
    ///   - available: The height the ticks may use from `top`.
    public init(groups: [[SidebarRailMark]], top: CGFloat, available: CGFloat, metrics: Metrics = Metrics()) {
        let runs = groups.filter { !$0.isEmpty }
        let count = runs.reduce(0) { $0 + $1.count }
        guard count > 0, available > 0 else { return }
        let natural = CGFloat(count) * metrics.pitch + CGFloat(runs.count - 1) * metrics.groupGap
        scale = min(1, available / natural)
        pitch = metrics.pitch * scale
        let gap = metrics.groupGap * scale
        let height = max(1, metrics.tickHeight * scale)
        var y = top
        for (index, run) in runs.enumerated() {
            if index > 0 { y += gap }
            for mark in run {
                let width = mark.isSelected ? metrics.selectedTickWidth : metrics.tickWidth
                ticks.append(Tick(mark: mark, rect: CGRect(x: 0, y: (y + (pitch - height) / 2).rounded(.down), width: width, height: height),
                                  rowY: y))
                y += pitch
            }
        }
    }

    /// The row a tick stands for, in the rail's (flipped) coordinates: the rail's full width and one
    /// pitch tall around the tick, so a group's rows touch and the pointer never falls between two
    /// of them. A row's hover card puts its top on the row's top.
    public func row(of tick: Tick, railWidth: CGFloat) -> CGRect {
        CGRect(x: 0, y: tick.rowY, width: railWidth, height: pitch)
    }

    /// The tick nearest `y` (flipped), within half a pitch; a click aims at a 2 pt line.
    public func tick(near y: CGFloat) -> Tick? {
        guard let nearest = ticks.min(by: { abs($0.rect.midY - y) < abs($1.rect.midY - y) }) else { return nil }
        let reach = max(3, (ticks.count > 1 ? abs(ticks[1].rect.midY - ticks[0].rect.midY) : 6) / 2 + 1)
        return abs(nearest.rect.midY - y) <= reach ? nearest : nil
    }
}
