import AppKit

/// The target of a card control: runs its closure on the control's action.
@MainActor
final class McpConnectButton: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}
