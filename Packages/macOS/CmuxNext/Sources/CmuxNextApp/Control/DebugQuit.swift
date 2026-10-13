import AppKit
import CmuxNextSettings

#if DEBUG
/// `debug.quit`: the quit sheet for automation (no system input needed).
/// `{}` reports it and never quits; the report's `quit_with` names the
/// socket actions that do (`action.run` `quitEndSessions` stops the app and
/// its daemon). `{open: true}` starts a quit exactly as Cmd-Q does
/// (interactive origin); `{remember: bool}` sets "Don't ask again";
/// `{open: true, inactive: true}` does it as a Dock quit of an inactive app;
/// `{fixture_quit: "keep" | "end-sessions" | "end-everything"}` quits with
/// that choice without showing the interactive sheet (DEBUG-only test fixture);
/// `{press: "keep" | "confirm-quit-everything" | "end-everything" | "quit" | "cancel"}`
/// clicks that button. While "Some sessions did not end" shows, the report
/// carries `failure` (its lines and buttons) and `press: "retry" |
/// "quit-anyway"` answers it.
@MainActor
enum DebugQuit {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let quit = services.quit
        // DEBUG-only fixture for tagged app behavior checks. The corresponding
        // socket actions are user-only, so a behavior test cannot tear down its
        // own app and sessions through action.run.
        if let choice = params["fixture_quit"]?.stringValue {
            let choices: [String: QuitSessionsChoice] = [
                "keep": .keep,
                "end-sessions": .endKeepLayout,
                "end-everything": .endEverything,
            ]
            guard let picked = choices[choice] else {
                return .object(["error": .string("fixture_quit: keep, end-sessions or end-everything")])
            }
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
        if let remember = params["remember"]?.boolValue { quit.sheet?.remembers = remember }
        var result = report(quit)
        if let id = params["press"]?.stringValue {
            result["pressed"] = .bool(quit.sheet?.press(id) ?? quit.failureAlert?.press(id) ?? false)
        }
        return .object(result)
    }

    /// The socket actions that quit with no sheet (`QuitOrigin.explicit`):
    /// this report never quits, so it says what does.
    private static let quitWith: JSONValue = .object([
        "method": .string("action.run"),
        "ids": .object([
            // Ends every local terminal and stops the local daemon; the layout reopens.
            "end_sessions": .string("quitEndSessions"),
            // Also deletes every local workspace first.
            "end_everything": .string("quitEndEverything"),
            // Leaves the terminals and the daemon running.
            "keep_sessions": .string("quitKeepSessions"),
        ]),
    ])

    private static func report(_ quit: QuitCoordinator) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["quitting": .bool(quit.isQuitting), "asking": .bool(quit.sheet != nil),
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
