import CmuxCommandPalette
import Foundation

/// A synchronous, window-targeted bridge from the control socket to the live
/// SwiftUI command-palette contribution and handler registry.
@MainActor
final class CommandPaletteControlRequest {
    /// The operation requested by the control socket.
    enum Operation {
        case list
        case run(commandID: String, arguments: [String: String], workingDirectory: String?)
    }

    /// A closure-free snapshot of one live palette action.
    struct Item {
        let id: String
        let title: String
        let subtitle: String
        let shortcutHint: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let arguments: [CmuxActionArgumentDefinition]
    }

    /// The result completed synchronously by the targeted `ContentView`.
    enum Result {
        case listed([Item])
        case ran(Item, result: CmuxActionExecutionResult)
        case commandNotFound
    }

    static let notificationUserInfoKey = "request"

    let operation: Operation
    private(set) var result: Result?

    init(operation: Operation) {
        self.operation = operation
    }

    /// Records the first result. Only the `ContentView` attached to the target
    /// window should answer, and later answers are ignored defensively.
    func complete(_ result: Result) {
        guard self.result == nil else { return }
        self.result = result
    }
}

extension Notification.Name {
    static let commandPaletteControlRequested = Notification.Name("cmux.commandPaletteControlRequested")
}
