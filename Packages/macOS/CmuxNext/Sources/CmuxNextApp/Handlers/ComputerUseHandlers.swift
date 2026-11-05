import CmuxNextActions
import CmuxNextComputerUse

/// Focus Computer Use, Focus Calling Terminal and Stop Computer Use (File
/// menu, `cmux agent focus-computer-use|focus-calling-terminal|stop-computer-use`).
/// Each acts on the newest live session the CUA host lists, as classic's menu
/// bar item acted on its first row (plans/cmux-next/computer-use.md section 6:
/// "re-bound to the store"). The work is tracked, so a CLI or MCP run answers
/// when it is done and gets the reason when there is nothing to act on.
enum ComputerUseHandlers {
    static func bind(into registry: ActionRegistry, sessions: any ComputerUseSessionControlling, focus: any ComputerUseFocusing) {
        func work(_ id: ActionID, _ body: @escaping @MainActor (ComputerUseLiveSession) async throws -> Void) {
            registry.bind(id, run: { _ in
                // task-owner: the action run; a capturing caller (CLI, MCP) awaits it through the registry.
                registry.track(Task { @MainActor in
                    do {
                        guard let newest = try await sessions.liveSessions().max(by: { $0.lastActionAt < $1.lastActionAt }) else {
                            throw ComputerUseSessionError.failed(ComputerUseSessionStrings.noLiveSession)
                        }
                        try await body(newest)
                        return nil
                    } catch {
                        let reason = (error as? ComputerUseSessionError)?.reason ?? String(describing: error)
                        registry.refuse(reason)
                        return ActionWorkFailure(refusal: .unavailable, reason: reason)
                    }
                })
            })
        }
        work("computerUseFocus") { session in
            guard focus.raiseTarget(of: session) else { throw ComputerUseSessionError.failed(ComputerUseSessionStrings.noTarget) }
        }
        work("computerUseFocusCallingTerminal") { session in
            guard focus.revealCallingTerminal(of: session) else {
                throw ComputerUseSessionError.failed(ComputerUseSessionStrings.noCallingTerminal)
            }
        }
        work("computerUseStop") { session in
            try await sessions.stop(session.id)
        }
    }
}
