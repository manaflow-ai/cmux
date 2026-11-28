public import CmuxHomeCore

/// One of my sends the owner has not confirmed, with the reason a refused
/// one was not delivered, as plain values: what a debug socket verb or a
/// test reads instead of a screenshot of the red mark.
public struct HomeDeliveryRow: Hashable, Sendable {
    public var key: IdempotencyKey
    /// `sending` or `notDelivered`.
    public var state: String
    /// Why it was not delivered (nil while sending).
    public var reason: String?
    public var mayHaveBeenDelivered: Bool
    /// Content hashes of its attachments, in part order.
    public var attachments: [String]
    /// Upload progress by hash while it uploads.
    public var progress: [String: Double]

    public init(_ item: TranscriptItem) {
        let (state, reason): (String, String?) = switch item.delivery {
        case .sending: ("sending", nil)
        case .notDelivered(let rejection): ("notDelivered", rejection.reportName)
        case .committed: ("committed", nil)
        }
        self.key = item.key
        self.state = state
        self.reason = reason
        self.mayHaveBeenDelivered = item.mayHaveBeenDelivered
        self.attachments = item.attachmentHashes
        self.progress = item.attachmentProgress
    }
}

extension Collection where Element == TranscriptItem {
    /// Rows for the items that have no sequence number yet (pending or refused).
    public var pendingDelivery: [HomeDeliveryRow] {
        filter { $0.seq == nil }.map(HomeDeliveryRow.init)
    }
}

extension HomeRejection {
    /// A stable, readable name for a refusal ("invalid: <code>").
    public var reportName: String {
        switch self {
        case .ownerUnreachable: "ownerUnreachable"
        case .notAuthorized: "notAuthorized"
        case .invalid(let code): "invalid: \(code)"
        case .rateLimited: "rateLimited"
        case .indeterminate: "indeterminate"
        }
    }
}
