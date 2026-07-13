import Foundation

/// A bounded snapshot drained from one child-process output descriptor.
struct CommandOutputCapture: Sendable {
    let data: Data
    let limitExceeded: Bool
}
