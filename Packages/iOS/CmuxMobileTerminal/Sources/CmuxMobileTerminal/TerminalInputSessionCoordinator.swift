#if canImport(UIKit)
import CmuxMobileTerminalKit
import UIKit

/// Main-actor adapter from the pure terminal input-session reducer to UIKit.
///
/// UIKit command return values are fed back into the reducer synchronously, so
/// requested focus never masquerades as actual ownership. UIKit/SwiftUI focus
/// observations use the same event path for user-driven responder changes.
@MainActor
final class TerminalInputSessionCoordinator {
    typealias FocusExecutor = (TerminalInputOwner) -> Bool
    typealias ResignExecutor = (TerminalInputOwner) -> Bool
    typealias ActualOwnerObserver = (TerminalInputOwner?) -> Void

    private(set) var state = TerminalInputSessionState()

    private let focus: FocusExecutor
    private let resign: ResignExecutor
    private let actualOwnerDidChange: ActualOwnerObserver
    private var publishedActualOwner: TerminalInputOwner?

    init(
        focus: @escaping FocusExecutor,
        resign: @escaping ResignExecutor,
        actualOwnerDidChange: @escaping ActualOwnerObserver
    ) {
        self.focus = focus
        self.resign = resign
        self.actualOwnerDidChange = actualOwnerDidChange
    }

    @discardableResult
    func send(_ event: TerminalInputSessionEvent) -> TerminalInputSessionTransition {
        let transition = state.handle(event)
        publishActualOwnerIfNeeded()
        execute(transition.commands)
        return transition
    }

    private func execute(_ commands: [TerminalInputSessionCommand]) {
        for command in commands {
            let followUp: TerminalInputSessionTransition
            switch command {
            case .focus(let owner):
                followUp = state.handle(
                    .focusCompleted(owner: owner, succeeded: focus(owner))
                )
            case .resign(let owner):
                followUp = state.handle(
                    .resignCompleted(owner: owner, succeeded: resign(owner))
                )
            }
            publishActualOwnerIfNeeded()
            execute(followUp.commands)
        }
    }

    private func publishActualOwnerIfNeeded() {
        guard publishedActualOwner != state.actualOwner else { return }
        publishedActualOwner = state.actualOwner
        actualOwnerDidChange(state.actualOwner)
    }
}
#endif
