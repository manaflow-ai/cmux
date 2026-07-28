import CmuxCommandPalette
import Foundation

extension CmuxActionExecutionResult {
    /// The shared failure for an action whose captured UI target disappeared.
    static var targetUnavailable: Self {
        .failed(
            code: "target_unavailable",
            message: String(
                localized: "action.error.targetUnavailable",
                defaultValue: "The action target is no longer available."
            )
        )
    }
}

/// A synchronous, window-targeted bridge from the control socket to the live
/// SwiftUI command-palette contribution and handler registry.
@MainActor
final class CommandPaletteControlRequest {
    typealias Operation = CommandPaletteControlRequestOperation
    typealias Item = CommandPaletteControlRequestItem
    typealias Result = CommandPaletteControlRequestResult

    let target: CommandPaletteActionTarget
    let operation: Operation
    private(set) var result: Result?

    init(target: CommandPaletteActionTarget, operation: Operation) {
        self.target = target
        self.operation = operation
    }

    /// Records the first result. Only the `ContentView` attached to the target
    /// window should answer, and later answers are ignored defensively.
    func complete(_ result: Result) {
        guard self.result == nil else { return }
        self.result = result
    }
}
