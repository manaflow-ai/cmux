public import Foundation

/// App-bundle-resolved messages for system tab-action close failures.
public struct ControlSystemCloseStrings: Sendable, Equatable {
    public let confirmationRequired: String

    public init(confirmationRequired: String) {
        self.confirmationRequired = confirmationRequired
    }
}

public extension ControlSystemContext {
    func controlSystemCloseStrings() -> ControlSystemCloseStrings {
        ControlSystemCloseStrings(
            confirmationRequired: "One or more surfaces have a running process; retry with force=true"
        )
    }
}
