import CmuxNextSettings

#if DEBUG
/// `debug.quit`: the quit sheet for automation (no system input needed).
/// `{}` reports it; `{open: true}` starts a quit exactly as Cmd-Q does
/// (interactive origin); `{remember: bool}` sets "Don't ask again";
/// `{press: "keep" | "end" | "quit" | "cancel"}` clicks that button.
@MainActor
enum DebugQuit {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let quit = services.quit
        if params["open"]?.boolValue == true {
            let started = !quit.isQuitting
            quit.requestQuit(.interactive)
            return .object(["requested": .bool(started)])
        }
        if let remember = params["remember"]?.boolValue { quit.sheet?.remembers = remember }
        var result = report(quit)
        if let id = params["press"]?.stringValue {
            result["pressed"] = .bool(quit.sheet?.press(id) ?? false)
        }
        return .object(result)
    }

    private static func report(_ quit: QuitCoordinator) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["quitting": .bool(quit.isQuitting), "asking": .bool(quit.sheet != nil)]
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
        ])
        result["lines"] = .array(sheet.lines.map { .string($0) })
        result["buttons"] = .array(sheet.buttons.map { entry in
            .object(["id": .string(entry.id), "title": .string(entry.button.title),
                     "key_equivalent": .string(entry.button.keyEquivalent == "\r" ? "return"
                         : entry.button.keyEquivalent == "\u{1b}" ? "escape" : entry.button.keyEquivalent)])
        })
        result["remember"] = .bool(sheet.remembers)
        result["attached"] = .bool(sheet.isAttachedSheet)
        return result
    }
}
#endif
