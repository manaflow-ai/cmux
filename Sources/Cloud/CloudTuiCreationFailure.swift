import Foundation

/// Typed outcomes for a durable Cloud terminal creation intent.
enum CloudTuiCreationFailure: Error, Equatable, Sendable {
    case outcomeUnknown
    case unsupported
}
