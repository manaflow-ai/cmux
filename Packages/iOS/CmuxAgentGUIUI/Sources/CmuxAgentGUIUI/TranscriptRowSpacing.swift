import CmuxAgentGUIProjection
import Foundation

struct TranscriptRowSpacing: Hashable, Sendable {
    let top: CGFloat
    let bottom: CGFloat
    let density: TranscriptDensity

    init(top: CGFloat, bottom: CGFloat, density: TranscriptDensity = .comfortable) {
        self.top = top
        self.bottom = bottom
        self.density = density
    }

    static func resolved(
        for rows: [TranscriptRow],
        density: TranscriptDensity = .comfortable
    ) -> [TranscriptRowID: Self] {
        let register = register(for: density)
        let terminalBottomGap = TranscriptRowSpacing.register(for: .comfortable).interGroup
        var result: [TranscriptRowID: Self] = [:]
        for index in rows.indices {
            let topGap = rows.indices.contains(index + 1)
                ? gap(betweenNewer: rows[index], older: rows[index + 1], register: register)
                : register.interGroup
            let bottomGap = rows.indices.contains(index - 1)
                ? gap(betweenNewer: rows[index - 1], older: rows[index], register: register)
                : terminalBottomGap
            result[rows[index].rowID] = Self(
                top: topGap / 2,
                bottom: bottomGap / 2,
                density: density
            )
        }
        return result
    }

    static func gap(
        betweenNewer newer: TranscriptRow,
        older: TranscriptRow,
        density: TranscriptDensity = .comfortable
    ) -> CGFloat {
        gap(betweenNewer: newer, older: older, register: register(for: density))
    }

    static func register(for density: TranscriptDensity) -> TranscriptRowSpacingRegister {
        TranscriptRowSpacingRegister.register(for: density)
    }

    private static func gap(
        betweenNewer newer: TranscriptRow,
        older: TranscriptRow,
        register: TranscriptRowSpacingRegister
    ) -> CGFloat {
        if older.endsTurn {
            return register.turnBottom
        }
        if case .activityItem = newer.rowKind, case .activityItem = older.rowKind {
            return register.activityItem
        }
        guard let newerProse = proseDescriptor(newer.rowKind), let olderProse = proseDescriptor(older.rowKind) else {
            return register.activity
        }
        let connected = newerProse.role == olderProse.role
            && [.last, .middle].contains(newerProse.grouping)
            && [.first, .middle].contains(olderProse.grouping)
        return connected ? register.intraGroup : register.interGroup
    }

    private static func proseDescriptor(
        _ rowKind: TranscriptRowKind
    ) -> (role: Int, grouping: TranscriptProseGrouping)? {
        switch rowKind {
        case .proseAgent(_, let grouping):
            (0, grouping)
        case .proseUser(_, _, let grouping, _, _):
            (1, grouping)
        case .pendingTicket, .streaming:
            (2, .single)
        case .status, .dateHeader, .boundary, .hole, .pendingAsk, .genericActivity, .activitySummary, .activityItem, .unsupported:
            nil
        }
    }
}
