import CmuxNextDesign
import CoreGraphics
import Foundation

/// Drag to group (Leo, 2026-10-06): the pointer's place in the row under
/// it decides. The outer quarters reorder; over the middle half the drop
/// groups, but only once the pointer has rested there for `dwell`, and it
/// holds until the pointer leaves the wider `holdZone`, so reorder and
/// group never flicker between each other.
nonisolated struct SidebarGroupDwell: Sendable {
    enum Phase: Hashable, Sendable {
        case none
        /// Over a middle, waiting out the dwell: rows hold still.
        case pending(DropTarget)
        /// A release groups (`ontoWorkspace`) or joins (`intoGroup`).
        case armed(DropTarget)
    }

    /// The row under the pointer that a drop could group with, and the
    /// pointer's place in it (0 top, 1 bottom).
    struct Hit: Hashable, Sendable {
        var target: DropTarget
        var fraction: CGFloat

        init(target: DropTarget, fraction: CGFloat) {
            self.target = target
            self.fraction = fraction
        }
    }

    static let zone: ClosedRange<CGFloat> = 0.25...0.75
    static let holdZone: ClosedRange<CGFloat> = 0.15...0.85
    static let dwell: TimeInterval = 0.275

    private(set) var phase = Phase.none
    private var since: TimeInterval = 0

    init() {}

    @discardableResult
    mutating func update(_ hit: Hit?, now: TimeInterval) -> Phase {
        let current: DropTarget? = switch phase {
        case .none: nil
        case let .pending(target), let .armed(target): target
        }
        guard let hit else {
            phase = .none
            return phase
        }
        if hit.target == current, case .armed = phase, Self.holdZone.contains(hit.fraction) { return phase }
        guard Self.zone.contains(hit.fraction) else {
            phase = .none
            return phase
        }
        if hit.target != current || phase == .none { since = now }
        // A millisecond of slack: clock sums are not exact.
        phase = now - since >= Self.dwell - 0.001 ? .armed(hit.target) : .pending(hit.target)
        return phase
    }

    /// What a drop of `dragged` could group with at display `y`: a loose
    /// row of the same machine (a new group), or a group header or grouped
    /// row (join that group). Pinned rows, headers and other machines can't.
    static func hit(y: CGFloat, rows: [SidebarRow], hidden: Set<SidebarRowKey>, dragged: [WorkspaceID],
                           sections: [SidebarSection]) -> Hit? {
        guard let row = rows.first(where: { y >= $0.y && y < $0.maxY && !hidden.contains($0.key) }), row.height > 0,
              case let .machine(machine) = row.section,
              dragged.allSatisfy({ SidebarEdits.workspace($0, in: sections)?.machineID == machine }) else { return nil }
        let target: DropTarget
        switch row.key {
        case let .workspace(id):
            if let group = row.group {
                target = .intoGroup(group)
            } else {
                target = .ontoWorkspace(id)
            }
        case let .group(group):
            target = .intoGroup(group)
        case .tab, .section, .emptySection:
            return nil
        }
        if case let .intoGroup(group) = target {
            let members: Set<WorkspaceID> = SidebarEdits.locateGroup(group, in: sections).map { s, n in
                guard case let .group(found) = sections[s].nodes[n] else { return [] }
                return Set(found.workspaces.map(\.id))
            } ?? []
            if dragged.allSatisfy(members.contains) { return nil }
        }
        return Hit(target: target, fraction: (y - row.y) / row.height)
    }

    /// The first color no group in `sections` uses yet, so a new group
    /// stands apart; blue once every color is taken.
    static func newGroupColor(in sections: [SidebarSection]) -> GroupColor {
        let used = Set(sections.flatMap(\.nodes).compactMap { node -> GroupColor? in
            if case let .group(group) = node { return group.color }
            return nil
        })
        return GroupColor.allCases.first { $0 != .grey && !used.contains($0) } ?? .blue
    }
}
