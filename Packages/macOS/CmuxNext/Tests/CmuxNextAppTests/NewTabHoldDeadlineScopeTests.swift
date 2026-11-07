import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// The New Tab key hold's limit (`NewTabInputCoordinator.scheduleDeadline`) ends the hold in a turn of its own, never
/// inside the task-local values of the run that opened the hold, as the creation hold's bounds do (#35935). The limit
/// gives the held keys back (`release`, the window's `sendEvent`): run inside the opening run's `ActionRunScope`, a key
/// held after a CLI's or a script's Cmd-T was judged as that run's (`ActionRunScope.viewChangeAllowed`), and one held
/// after a menu pick carried the pick's mark (`ActionRunScope.menuPick`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NewTabHoldDeadlineScopeTests {
    /// What the limit saw when it fired.
    @MainActor private final class Seen {
        var fired = false
        var scope: ActionRunScope?
        var task: Task<Void, Never>?
    }

    @Test func theHoldLimitFiresOutsideTheRunThatArmedIt() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let input = services.keyRouter.newTabInputCoordinator
        let seen = Seen()
        // As `install` arms it for a hold that a CLI run's Cmd-T opened.
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            seen.task = input.scheduleDeadline(.milliseconds(50)) { (seen.fired, seen.scope) = (true, ActionRunScope.current) }
        }
        await seen.task?.value
        #expect(seen.fired, "the hold limit never fired")
        #expect(seen.scope == nil, "the hold limit fired inside the arming run's scope: \(String(describing: seen.scope))")
    }
}
