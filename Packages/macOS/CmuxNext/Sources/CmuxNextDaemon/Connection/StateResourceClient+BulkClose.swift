import Foundation

extension StateResourceClient {
    /// The level at which a `layout.bulk` close names its objects.
    public enum BulkCloseLevel: String, Sendable, Equatable {
        /// Tabs (`tab_…` ids).
        case tab
        /// Panes (`pane_…` ids) with every tab they hold.
        case pane
        /// Screens (`screen_…` ids) with their panes and tabs.
        case screen
        /// Workspaces (`ws_…` ids) with their screens.
        case workspace
    }

    /// What one `layout.bulk` close took out of the layout.
    public struct BulkClosed: Decodable, Sendable, Equatable {
        /// The closed-history groups the close stored: one for the whole gesture
        /// (empty when nothing had a tab to close).
        public var closedIDs: [String]
        /// Every tab the close took, of every object.
        public var tabIDs: [ResourceID]

        enum CodingKeys: String, CodingKey {
            case closedIDs = "closed_ids"
            case tabIDs = "tab_ids"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            closedIDs = try c.decodeIfPresent([String].self, forKey: .closedIDs) ?? []
            tabIDs = try c.decodeIfPresent([ResourceID].self, forKey: .tabIDs) ?? []
        }
    }

    /// Closes `ids` (objects at `level`, on any container of the session) in
    /// one daemon commit (`layout.bulk` with selector `selection`,
    /// `layout-bulk-v1`): the gesture is ONE closed-history group, so one
    /// Reopen Closed (Cmd-Shift-T) brings every object back to its place.
    ///
    /// The daemon skips an object with no tab (an empty workspace stays open)
    /// and never closes the home workspace.
    ///
    /// The close ends on the daemon's reply or refusal, or the connection's
    /// end, never on the 2 s client deadline: a busy daemon commits a close it
    /// answers late, and one that gave up first reported a done close as failed.
    ///
    /// ```swift
    /// try await connection.state.closeBulk(.screen, ids: screens.compactMap(\.resourceID))
    /// ```
    ///
    /// - Parameters:
    ///   - level: The level `ids` name.
    ///   - ids: The public ids of the objects to close.
    ///   - endTerminals: End the terminals whose every view closes (as a
    ///     workspace close does); false keeps them for the reap grace period.
    /// - Returns: The stored closed groups and the closed tabs.
    /// - Throws: `DaemonError.command` with `resource.not_found` when an id is
    ///   unknown, or a refusal when an id names Home's pinned pane.
    @discardableResult
    public func closeBulk(_ level: BulkCloseLevel, ids: [ResourceID], endTerminals: Bool = false) async throws -> BulkClosed {
        try await stateMutation("layout.bulk", [
            "verb": .string("close"), "level": .string(level.rawValue), "selector": .string("selection"),
            "ids": Self.ids(ids), "end_terminals": .bool(endTerminals),
        ], as: BulkClosed.self, awaitingReply: true)
    }
}
