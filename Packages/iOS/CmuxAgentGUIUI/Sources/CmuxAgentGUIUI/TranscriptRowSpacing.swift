import CmuxAgentGUIProjection
import Foundation

struct TranscriptRowSpacing: Hashable, Sendable {
    static let intraGroup: CGFloat = 4
    static let interGroup: CGFloat = 12
    static let activity: CGFloat = 8
    static let activityItem: CGFloat = 1
    static let turnBottom: CGFloat = 16

    let top: CGFloat
    let bottom: CGFloat

    init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }

    static func resolved(for rows: [TranscriptRow]) -> [TranscriptRowID: Self] {
        var result: [TranscriptRowID: Self] = [:]
        for index in rows.indices {
            let topGap = rows.indices.contains(index + 1)
                ? gap(betweenNewer: rows[index], older: rows[index + 1])
                : interGroup
            let bottomGap = rows.indices.contains(index - 1)
                ? gap(betweenNewer: rows[index - 1], older: rows[index])
                : interGroup
            result[rows[index].rowID] = Self(top: topGap / 2, bottom: bottomGap / 2)
        }
        return result
    }

    static func gap(betweenNewer newer: TranscriptRow, older: TranscriptRow) -> CGFloat {
        if older.endsTurn {
            return turnBottom
        }
        if case .activityItem = newer.rowKind, case .activityItem = older.rowKind {
            return activityItem
        }
        guard let newerProse = proseDescriptor(newer.rowKind), let olderProse = proseDescriptor(older.rowKind) else {
            return activity
        }
        let connected = newerProse.role == olderProse.role
            && [.last, .middle].contains(newerProse.grouping)
            && [.first, .middle].contains(olderProse.grouping)
        return connected ? intraGroup : interGroup
    }

    private static func proseDescriptor(
        _ rowKind: TranscriptRowKind
    ) -> (role: Int, grouping: TranscriptProseGrouping)? {
        switch rowKind {
        case .proseAgent(_, let grouping):
            (0, grouping)
        case .proseUser(_, _, let grouping):
            (1, grouping)
        case .pendingTicket, .streaming:
            (2, .single)
        case .status, .dateHeader, .boundary, .hole, .pendingAsk, .genericActivity, .activitySummary, .activityItem, .unsupported:
            nil
        }
    }
}
