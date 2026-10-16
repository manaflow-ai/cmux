public import Foundation

/// App-bundle-resolved messages returned by `surface.close`.
public struct ControlSurfaceCloseStrings: Sendable, Equatable {
    public let confirmationRequired: String
    public let failed: String

    public init(confirmationRequired: String, failed: String) {
        self.confirmationRequired = confirmationRequired
        self.failed = failed
    }
}

public extension ControlSurfaceContext {
    func controlSurfaceCloseStrings() -> ControlSurfaceCloseStrings {
        ControlSurfaceCloseStrings(
            confirmationRequired: "Surface has a running process; retry with force=true",
            failed: "Failed to close surface"
        )
    }
}
