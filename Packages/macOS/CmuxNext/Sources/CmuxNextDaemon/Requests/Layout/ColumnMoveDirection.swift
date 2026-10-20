import Foundation

/// The neighbor a viewport column trades places with (`move-column`).
public enum ColumnMoveDirection: String, Sendable, Hashable, Codable {
    case left, right
}
