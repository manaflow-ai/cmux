import Foundation

struct TmuxCompatArgumentError: Error, LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}
