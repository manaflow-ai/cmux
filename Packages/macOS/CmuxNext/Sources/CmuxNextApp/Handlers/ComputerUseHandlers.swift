import CmuxNextActions
import CmuxNextComputerUse

/// Focus Computer Use, Focus Calling Terminal and Stop Computer Use (File
/// menu, `cmux agent focus-computer-use|focus-calling-terminal|stop-computer-use`).
/// The focus actions act on the newest live session the host lists, as classic's menu
/// bar item acted on its first row, or on the session a `session` argument names (the menu bar's
/// per-agent Show Window); Stop ends every session, or the one `session` names (the menu bar's
/// per-agent Stop: its calls are refused with `stopped_by_person` until Resume)
/// (plans/cmux-next/computer-use.md section 6: "re-bound to the store"). The work is tracked, so a
/// CLI or MCP run answers when it is done and gets the reason when there is nothing to act on.
enum ComputerUseHandlers {
    static func bind(into registry: ActionRegistry, sessions: any ComputerUseSessionControlling, focus: any ComputerUseFocusing) {
        func work(_ id: ActionID, _ body: @escaping @MainActor (ComputerUseLiveSession) async throws -> Void) {
            registry.bind(id, run: { invocation in
                // A row's drive indicator passes its agent's `terminals` (comma-separated): their session goes first.
                let terminals = Set((invocation.arguments["terminals"]?.stringValue ?? "").split(separator: ",").map(String.init))
                // The menu bar's per-agent rows name their session.
                let named = invocation.arguments["session"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                // task-owner: the action run; a capturing caller (CLI, MCP) awaits it through the registry.
                registry.track(Task { @MainActor in
                    do {
                        let live = try await sessions.liveSessions()
                        let picked = named.map { id in live.first { $0.id == id } } ?? ComputerUseLiveSession.pick(live, terminals: terminals)
                        guard let newest = picked else {
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
            // The window the agent works in first (within its app, by cmux Remote), then its app in
            // front: the person asked to see it. A window the worker cannot raise still brings the app.
            try? await sessions.raiseWindow(session.id)
            guard focus.raiseTarget(of: session) else { throw ComputerUseSessionError.failed(ComputerUseSessionStrings.noTarget) }
        }
        work("computerUseFocusCallingTerminal") { session in
            guard focus.revealCallingTerminal(of: session) else {
                throw ComputerUseSessionError.failed(ComputerUseSessionStrings.noCallingTerminal)
            }
        }
        // Stops the session a `session` argument names (the menu bar's per-agent Stop), else every
        // session: the person's stop must not depend on a session list the host may not give.
        _ = registry.bindEffect("computerUseStop", effect: { invocation in
            let named = invocation.arguments["session"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            // action-wait-allow: the stop runs in cmux Remote's Computer Use worker, another process, through the daemon.
            return .waiting(.externalProcess) {
                do {
                    if let named { try await sessions.stop(named) } else { try await sessions.stopAll() }
                    return nil
                } catch {
                    return ActionWorkFailure(refusal: .unavailable,
                                             reason: (error as? ComputerUseSessionError)?.reason ?? String(describing: error))
                }
            }
        })
    }
}
