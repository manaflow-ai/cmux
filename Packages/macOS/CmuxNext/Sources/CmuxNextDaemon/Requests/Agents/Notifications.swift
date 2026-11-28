import Foundation

/// `ack-tab-notifications` emits `tab-changed` for each view whose marker cleared.
extension AckTabNotificationsRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var cleared: Bool
        public var acknowledged: [String]
        /// Local feed items of the tab owned elsewhere (`feed-local-owner-v1`):
        /// `feed.moving` while handing off, `owner.unreachable` once moved.
        /// Nil on older daemons.
        public var refused: [Refused]?
        public init(surface: SurfaceID, cleared: Bool, acknowledged: [String], refused: [Refused]? = nil) {
            self.surface = surface
            self.cleared = cleared
            self.acknowledged = acknowledged
            self.refused = refused
        }
    }
    /// One local feed item the ack could not read.
    public struct Refused: Decodable, Sendable, Hashable {
        public var item: String
        public var code: String
        public var retryable: Bool
        public init(item: String, code: String, retryable: Bool = true) {
            self.item = item
            self.code = code
            self.retryable = retryable
        }
    }
}

/// The retained ledger (at most 256), newest first (`notification-ack-v1`).
extension ListNotificationsRequest {
    public struct Entry: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var body: String
        public var level: NotificationLevel
        public var terminalID: TerminalID?
        public var surface: SurfaceID?
        public var createdAtMs: UInt64
        public var acknowledged: Bool
        /// The producer category the daemon reports for the row (`cli`,
        /// `terminal`, `agent` or `daemon`; `NotificationSource` in
        /// cmux-tui). Optional so a daemon that predates it still decodes.
        public var source: String?

        enum CodingKeys: String, CodingKey {
            case id, title, subtitle, body, level, surface, acknowledged, source
            case terminalID = "terminal_id"
            case createdAtMs = "created_at_ms"
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var notifications: [Entry]
    }
}
