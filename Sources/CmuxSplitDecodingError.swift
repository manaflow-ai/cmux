import Foundation

/// Identifies a split whose persisted child count violates the layout schema.
enum CmuxSplitDecodingError: Error, Equatable, Sendable, LocalizedError {
    case invalidChildCount(Int)

    var errorDescription: String? {
        switch self {
        case .invalidChildCount(let count):
            return String(
                format: String(
                    localized: "config.validation.splitChildCount",
                    defaultValue: "Split layout must contain exactly 2 children (found %@)"
                ),
                String(count) as NSString
            )
        }
    }
}
