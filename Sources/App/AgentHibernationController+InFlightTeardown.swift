import CmuxTerminal
import Foundation
import os

extension AgentHibernationController {
    final class InFlightTeardown: @unchecked Sendable {
        let requestID: UUID
        private weak var terminalSurface: TerminalSurface?

        private enum State {
            case valid
            case invalidated
            case claimed
        }

        private let state = OSAllocatedUnfairLock(initialState: State.valid)

        @MainActor
        init(requestID: UUID, terminalSurface: TerminalSurface) {
            self.requestID = requestID
            self.terminalSurface = terminalSurface
        }

        @MainActor
        func invalidate() {
            // Always revoke the package's last native-free gate, including
            // when the controller token was already claimed. This closes the
            // handoff gap between the outer claim and the package's claim.
            terminalSurface?.invalidateProvisionalAgentHibernation()
            state.withLock { value in
                if value == .valid { value = .invalidated }
            }
        }

        /// One-way handoff immediately before native free. Once claimed, later
        /// activity cannot turn a committed free into an unsafe restoration.
        func claim() -> Bool {
            state.withLock { value in
                guard value == .valid else { return false }
                value = .claimed
                return true
            }
        }
    }
}
