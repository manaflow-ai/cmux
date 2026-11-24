import AppKit
import CmuxNextSettings

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.quit` reports or drives a quit. `{}` reports; `{open: true}` starts
/// an interactive quit (Cmd-Q: it never asks), and `fixture_quit` performs a
/// DEBUG-only fixture quit. `{press: ...}` answers the failure alert.
/// `{wedge_engine_stop: true}` makes engine stop block for quit-deadline checks.
@MainActor
enum DebugQuit {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let quit = services.quit
        if params["wedge_engine_stop"]?.boolValue == true { quit.wedgesEngineStop = true }
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
        var result = report(quit)
        if let id = params["press"]?.stringValue {
            result["pressed"] = .bool(quit.failureAlert?.press(id) ?? false)
        }
        return .object(result)
    }

    /// The socket actions that quit with another choice (`QuitOrigin.explicit`):
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
        var result: [String: JSONValue] = ["quitting": .bool(quit.isQuitting),
                                           "wedges_engine_stop": .bool(quit.wedgesEngineStop), "quit_with": quitWith]
        if let failure = quit.failureAlert {
            result["failure"] = .object([
                "lines": .array(failure.lines.map { .string($0) }),
                "buttons": .array(failure.buttons.map { .string($0.id) }),
                "attached": .bool(failure.isAttachedSheet),
            ])
        }
        return result
    }
}
#endif
