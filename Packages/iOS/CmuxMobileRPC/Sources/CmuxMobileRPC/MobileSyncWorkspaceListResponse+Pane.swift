internal import Foundation

extension MobileSyncWorkspaceListResponse {
    /// A stable pane and its ordered terminal membership.
    public struct Pane: Decodable, Sendable {
        /// Stable pane identifier.
        public let id: String
        /// Zero-based spatial position.
        public let spatialIndex: Int
        /// Whether this pane currently holds focus.
        public let isFocused: Bool
        /// Terminal identities in tab order.
        public let terminalIDs: [String]

        private enum CodingKeys: String, CodingKey {
            case id
            case spatialIndex = "spatial_index"
            case isFocused = "is_focused"
            case terminalIDs = "terminal_ids"
        }
    }
}
