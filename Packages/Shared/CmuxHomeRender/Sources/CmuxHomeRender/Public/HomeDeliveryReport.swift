public import CmuxHomeCore

/// My sends the owner has not confirmed, with the reason a refused one
/// was not delivered, as plain values: what a debug socket verb or a test
/// reads instead of a screenshot of the red mark.
public enum HomeDeliveryReport {
    public struct Row: Hashable, Sendable {
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
    }

    /// Rows for the items that have no sequence number yet (pending or refused).
    public static func pending(_ items: [TranscriptItem]) -> [Row] {
        items.filter { $0.seq == nil }.map { item in
            let (state, reason): (String, String?) = switch item.delivery {
            case .sending: ("sending", nil)
            case .notDelivered(let rejection): ("notDelivered", describe(rejection))
            case .committed: ("committed", nil)
            }
            return Row(key: item.key, state: state, reason: reason, mayHaveBeenDelivered: item.mayHaveBeenDelivered,
                       attachments: item.attachmentHashes, progress: item.attachmentProgress)
        }
    }

    /// A stable, readable name for a refusal ("invalid: <code>").
    public static func describe(_ rejection: HomeRejection) -> String {
        switch rejection {
        case .ownerUnreachable: "ownerUnreachable"
        case .notAuthorized: "notAuthorized"
        case .invalid(let code): "invalid: \(code)"
        case .rateLimited: "rateLimited"
        case .indeterminate: "indeterminate"
        }
    }
}
