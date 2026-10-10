import AppKit
import CmuxNextDesign
import CmuxNextSettings

#if DEBUG
/// `debug.quit`: the quit sheet for automation (no system input needed).
/// `{}` reports it and never quits; the report's `quit_with` names what does
/// (`action.run quitKeepSessions`, or the `fixture_quit` test fixture). `{open: true}` starts a quit exactly as Cmd-Q does
/// (interactive origin); `{remember: bool}` sets "Don't ask again";
/// `{open: true, inactive: true}` does it as a Dock quit of an inactive app;
/// `{press: "keep" | "quit" | "cancel"}` clicks that button; the end choices
/// ("confirm-quit-everything", "end-everything") answer only to the user
/// (cx-zk9t), so scripts quit by `quit_with` instead.
/// Test fixtures (DEBUG only): `{fixture_discard_unsaved: true}` drops unsaved changes
/// (`discardUnsaved`, answered after the discard); `{fixture_quit: "keep" | "end-sessions"
/// | "end-everything"}` quits with that choice and no sheet. While "Some sessions did not end" shows, the report
/// carries `failure` (its lines and buttons) and `press: "retry" |
/// "quit-anyway"` answers it.
@MainActor
enum DebugQuit {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let quit = services.quit
        // DEV-only test fixture (cx-zk9t; this file is DEBUG-only, so no release build has it):
        // quits with a session choice and no sheet, for scripts that must end the sessions
        // (quitEndSessions and quitEndEverything are the person's on every socket path).
        if let choice = params["fixture_quit"]?.stringValue {
            let choices: [String: QuitSessionsChoice] = ["keep": .keep, "end-sessions": .endKeepLayout, "end-everything": .endEverything]
            guard let picked = choices[choice] else { return .object(["error": .string("fixture_quit: keep, end-sessions or end-everything")]) }
            quit.requestQuit(.explicit(picked))
            return .object(["quitting": .string(choice)])
        }
        if params["open"]?.boolValue == true {
            let started = !quit.isQuitting
            // `inactive`: as a quit from the Dock while cmux is in the background.
            if params["inactive"]?.boolValue == true { NSApp.deactivate() }
            quit.requestQuit(.interactive)
            return .object(["requested": .bool(started)])
        }
        // Through the dialog center's automation door (cx-zk9t): the quit sheet is
        // destructive, so only Cancel passes; quit without it by `quit_with`.
        var refusal: CmuxDialogAutomationRefusal?
        do throws(CmuxDialogAutomationRefusal) {
            if let remember = params["remember"]?.boolValue { try quit.sheet?.automationRemember(remember) }
        } catch { refusal = error }
        var result = report(quit)
        if refusal == nil, let id = params["press"]?.stringValue {
            do throws(CmuxDialogAutomationRefusal) {
                if let sheet = quit.sheet {
                    result["pressed"] = .bool(try sheet.automationPress(id))
                } else {
                    result["pressed"] = .bool(try quit.failureAlert?.automationPress(id) ?? false)
                }
            } catch { refusal = error }
        }
        if let refusal {
            result["error"] = .string(refusal.message)
            result["refused"] = .object(["dialog": .number(Double(refusal.dialog)), "confirm_kind": .string(refusal.kind.rawValue)])
        }
        return .object(result)
    }

    /// DEV-only test fixture (cx-zk9t): drops every unsaved document's changes, so the next
    /// quit asks no "Don't Save" question; it replaces a Don't Save press, which automation
    /// may not make. Answers after the discard ends.
    static func discardUnsaved(_ services: AppServices) async -> JSONValue {
        let registry = services.quit.unsaved
        let participants = registry.unsaved()
        await registry.discard(participants)
        return .object(["discarded": .number(Double(participants.count)), "unsaved_documents": .number(Double(registry.unsaved().count))])
    }

    /// What quits with no sheet (`QuitOrigin.explicit`): this report never quits, so it says
    /// what does. Ending the sessions is the person's on the socket (cx-zk9t), so scripts
    /// use the DEBUG fixture for it.
    private static let quitWith: JSONValue = .object([
        // Leaves the terminals and the daemon running.
        "keep_sessions": .object(["method": "action.run", "id": "quitKeepSessions"]),
        // Ends every local terminal and stops the local daemon; the layout reopens.
        "end_sessions": .object(["method": "debug.quit", "fixture_quit": "end-sessions"]),
        // Also deletes every local workspace first.
        "end_everything": .object(["method": "debug.quit", "fixture_quit": "end-everything"]),
    ])

    private static func report(_ quit: QuitCoordinator) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["quitting": .bool(quit.isQuitting), "asking": .bool(quit.sheet != nil),
                                           "unsaved_documents": .number(Double(quit.unsaved.unsaved().count)),
                                           "activated": .bool(quit.lastAskActivated), "quit_with": quitWith]
        if let failure = quit.failureAlert {
            result["failure"] = .object([
                "lines": .array(failure.lines.map { .string($0) }),
                "buttons": .array(failure.buttons.map { .string($0.id) }),
                "attached": .bool(failure.isAttachedSheet),
            ])
        }
        guard let sheet = quit.sheet else { return result }
        let prompt = sheet.prompt
        result["prompt"] = .object([
            "terminals": .number(Double(prompt.terminals)),
            "running_programs": .number(Double(prompt.runningPrograms)),
            "busiest": .array(prompt.busiest.map { .string($0) }),
            "incognito_programs": .array(prompt.incognitoPrograms.map { .string($0) }),
            "remote_sessions": .bool(prompt.remoteSessions),
            "offers_session_choice": .bool(prompt.offersSessionChoice),
            "default": .string(prompt.defaultChoice.rawValue),
            "agents": prompt.agents.map { .number(Double($0)) } ?? .null,
            "agents_in_turn": .number(Double(prompt.agentsInTurn)),
            "busy_agents": .array(prompt.busyAgents.map { .string($0) }),
            "chief_keeps_running": .bool(prompt.chiefKeepsRunning),
        ])
        result["lines"] = .array(sheet.lines.map { .string($0) })
        result["buttons"] = .array(sheet.buttons.map { button in
            .object(["id": .string(button.id), "title": .string(button.title), "role": .string(button.role.rawValue)])
        })
        result["remember"] = .bool(sheet.remembers)
        result["attached"] = .bool(sheet.isAttached)
        return result
    }
}
#endif
