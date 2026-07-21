import Foundation

struct DockConfigValidationError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
