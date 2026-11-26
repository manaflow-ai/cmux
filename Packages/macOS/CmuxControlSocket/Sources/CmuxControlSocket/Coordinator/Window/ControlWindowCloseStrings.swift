public import Foundation

/// App-bundle-resolved messages returned by non-interactive window close.
public struct ControlWindowCloseStrings: Sendable, Equatable {
    public let confirmationRequired: String

    public init(confirmationRequired: String) {
        self.confirmationRequired = confirmationRequired
    }
}

public extension ControlWindowContext {
    func controlWindowCloseStrings() -> ControlWindowCloseStrings {
        ControlWindowCloseStrings(
            confirmationRequired: "One or more workspaces or Dock surfaces have a running process; retry with --force"
        )
    }

    func controlCloseWindow(id: UUID, force: Bool) -> ControlWindowCloseResolution {
        controlCloseWindow(id: id)
            ? .resolved
            : .notFound
    }
}
