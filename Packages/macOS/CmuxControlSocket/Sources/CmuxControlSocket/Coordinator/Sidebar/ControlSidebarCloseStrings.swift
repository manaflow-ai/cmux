public import Foundation

/// App-bundle-resolved messages for the legacy `close_surface` command.
public struct ControlSidebarCloseStrings: Sendable, Equatable {
    public let failed: String
    public let confirmationRequired: String

    public init(failed: String, confirmationRequired: String) {
        self.failed = failed
        self.confirmationRequired = confirmationRequired
    }
}

public extension ControlSidebarContext {
    func controlSidebarCloseStrings() -> ControlSidebarCloseStrings {
        ControlSidebarCloseStrings(
            failed: "Failed to close surface",
            confirmationRequired: "Surface has a running process; retry with --force"
        )
    }
}
