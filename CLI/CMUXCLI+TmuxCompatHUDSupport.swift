import Foundation

extension CMUXCLI {
    func tmuxBooleanValue(_ raw: Any?) -> Bool? {
        if let bool = raw as? Bool {
            return bool
        }
        if let number = raw as? NSNumber {
            return number.intValue != 0
        }
        guard let string = raw as? String else {
            return nil
        }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            return nil
        }
    }

    func tmuxDictionaryValue(_ raw: Any?) -> [String: Any]? {
        if let dictionary = raw as? [String: Any] {
            return dictionary
        }
        if let dictionary = raw as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }

    func tmuxHudConfigDictionaryDisablesHud(_ dictionary: [String: Any], allowTopLevelHUDKeys: Bool) -> Bool {
        if allowTopLevelHUDKeys {
            if tmuxBooleanValue(dictionary["enabled"]) == false {
                return true
            }
            if tmuxBooleanValue(dictionary["disabled"]) == true {
                return true
            }
        }

        if tmuxBooleanValue(dictionary["hudEnabled"]) == false {
            return true
        }
        if tmuxBooleanValue(dictionary["omxHudEnabled"]) == false {
            return true
        }
        if tmuxBooleanValue(dictionary["ompHudEnabled"]) == false {
            return true
        }
        if tmuxBooleanValue(dictionary["hudDisabled"]) == true {
            return true
        }
        if tmuxBooleanValue(dictionary["omxHudDisabled"]) == true {
            return true
        }
        if tmuxBooleanValue(dictionary["ompHudDisabled"]) == true {
            return true
        }

        let nestedCandidates: [Any?] = [
            dictionary["hud"],
            dictionary["omxHud"],
            dictionary["ompHud"],
            dictionary["hudPane"],
            tmuxDictionaryValue(dictionary["omx"])?["hud"],
            tmuxDictionaryValue(dictionary["omp"])?["hud"]
        ]
        for candidate in nestedCandidates {
            guard let nested = tmuxDictionaryValue(candidate) else { continue }
            if tmuxBooleanValue(nested["enabled"]) == false {
                return true
            }
            if tmuxBooleanValue(nested["disabled"]) == true {
                return true
            }
        }

        return false
    }

    func tmuxHudConfigFileDisablesHud(_ url: URL, allowTopLevelHUDKeys: Bool) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return false
        }
        return tmuxHudConfigDictionaryDisablesHud(dictionary, allowTopLevelHUDKeys: allowTopLevelHUDKeys)
    }

    /// Which managed launcher owns a tmux HUD command.
    ///
    /// The split, resize, and restore rules are identical for every provider, so
    /// the provider carries its own shim environment, launch kind, command words,
    /// and config paths as data instead of the rules being copied per provider.
    enum TmuxCompatHudProvider: String, CaseIterable {
        case omx
        case omp

        var displayName: String { rawValue.uppercased() }

        var shimBinaryEnvironmentKey: String { "CMUX_\(displayName)_CMUX_BIN" }

        var commandWords: [String] {
            switch self {
            case .omx: return ["omx", "oh-my-codex"]
            case .omp: return ["omp", "oh-my-pi"]
            }
        }

        var enabledEnvironmentKeys: [String] {
            ["\(displayName)_HUD_ENABLED", "CMUX_\(displayName)_HUD_ENABLED"]
        }

        var disabledEnvironmentKeys: [String] {
            ["\(displayName)_HUD_DISABLED", "CMUX_\(displayName)_HUD_DISABLED"]
        }

        /// HUD config files in the working directory. A provider's own HUD file
        /// allows the top-level `enabled`/`disabled` spelling; a shared config file
        /// only honours HUD-scoped keys.
        var workingDirectoryConfigCandidates: [(relativePath: String, allowTopLevelHUDKeys: Bool)] {
            switch self {
            case .omx:
                return [
                    (".omx/hud-config.json", true),
                    (".omx/config.json", false),
                    (".omx-config.json", false)
                ]
            case .omp:
                return [
                    (".omp/hud-config.json", true),
                    (".omp/config.json", false),
                    (".omp-config.json", false)
                ]
            }
        }

        var homeConfigCandidates: [(relativePath: String, allowTopLevelHUDKeys: Bool)] {
            switch self {
            case .omx:
                return [
                    (".omx/hud-config.json", true),
                    (".omx/config.json", false),
                    (".codex/.omx-config.json", false)
                ]
            case .omp:
                return [
                    (".omp/hud-config.json", true),
                    (".omp/config.json", false),
                    (".omp-config.json", false)
                ]
            }
        }
    }

    func tmuxHudConfigDisablesHud(cwd: String?, provider: TmuxCompatHudProvider) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if provider.enabledEnvironmentKeys.contains(where: { tmuxBooleanValue(environment[$0]) == false })
            || provider.disabledEnvironmentKeys.contains(where: { tmuxBooleanValue(environment[$0]) == true }) {
            return true
        }

        var candidates: [(URL, Bool)] = []
        let fileManager = FileManager.default
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let cwdURL = URL(fileURLWithPath: resolvePath(cwd), isDirectory: true)
            candidates.append(contentsOf: provider.workingDirectoryConfigCandidates.map {
                (cwdURL.appendingPathComponent($0.relativePath), $0.allowTopLevelHUDKeys)
            })
        }

        let homePath = environment["HOME"] ?? NSHomeDirectory()
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
        candidates.append(contentsOf: provider.homeConfigCandidates.map {
            (homeURL.appendingPathComponent($0.relativePath), $0.allowTopLevelHUDKeys)
        })

        for (url, allowTopLevelHUDKeys) in candidates where fileManager.isReadableFile(atPath: url.path) {
            if tmuxHudConfigFileDisablesHud(url, allowTopLevelHUDKeys: allowTopLevelHUDKeys) {
                return true
            }
        }

        return false
    }

    func tmuxCommandTextContainsWord(_ commandText: String, word: String) -> Bool {
        let escapedWord = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(^|[^A-Za-z0-9_-])\(escapedWord)([^A-Za-z0-9_-]|$)"
        return commandText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The provider whose HUD this command starts, or nil when it is not a HUD command.
    ///
    /// The provider must identify the command being executed — its program, or
    /// the script an interpreter runs, after any leading `env`/`NAME=value`
    /// prefix — so an ordinary command that merely mentions the words
    /// (`echo 'omp hud'`) is not a HUD launch. A shim-owned pane
    /// (`CMUX_<PROVIDER>_CMUX_BIN`, `CMUX_AGENT_LAUNCH_KIND`) is trusted only for
    /// the `hud --watch` form the providers actually run. Provider words match on
    /// boundaries so `prompt` cannot be read as `omp`.
    func tmuxHudProviderForCommand(_ commandTokens: [String]) -> TmuxCompatHudProvider? {
        let commandText = commandTokens.joined(separator: " ")
        let lowered = commandText.lowercased()
        guard tmuxCommandTextContainsWord(lowered, word: "hud") else {
            return nil
        }

        if let provider = tmuxHudProviderExecutingCommand(commandTokens) {
            return provider
        }

        // The watch flag is matched literally: `--watch` is one token, so a word
        // boundary around "watch" would never match it.
        guard lowered.contains("--watch") else {
            return nil
        }

        // `CMUX_AGENT_LAUNCH_KIND` is the more specific signal: a launcher records it
        // for the process it started, while a shim binary path can be inherited from an
        // outer provider's shell.
        let environment = ProcessInfo.processInfo.environment
        if let launchKind = environment["CMUX_AGENT_LAUNCH_KIND"],
           let provider = TmuxCompatHudProvider(rawValue: launchKind.lowercased()) {
            return provider
        }

        for provider in TmuxCompatHudProvider.allCases
        where environment[provider.shimBinaryEnvironmentKey] != nil {
            return provider
        }

        return nil
    }

    /// The provider a command actually runs, or nil when the provider words
    /// appear only in its argument text. A leading `env` and `NAME=value`
    /// prefix is skipped first, and an interpreter's script argument identifies
    /// its provider the way a directly executed provider binary does:
    /// `omp hud`, `node omp.js hud`, and
    /// `env OMP_SESSION_ID=x node '/opt/oh-my-pi/dist/cli/omp.js' hud` all run
    /// the omp HUD, while `echo 'omp hud'` runs echo.
    func tmuxHudProviderExecutingCommand(_ commandTokens: [String]) -> TmuxCompatHudProvider? {
        var index = 0
        while index < commandTokens.count,
              commandTokens[index] == "env" || tmuxHudIsEnvironmentAssignment(commandTokens[index]) {
            index += 1
        }
        guard index < commandTokens.count else {
            return nil
        }

        if let provider = tmuxHudProviderForExecutableName(commandTokens[index]) {
            return provider
        }
        guard tmuxHudInterpreterNames.contains(tmuxHudExecutableName(commandTokens[index])),
              index + 1 < commandTokens.count else {
            return nil
        }
        for component in commandTokens[index + 1].split(separator: "/") {
            if let provider = tmuxHudProviderForExecutableName(String(component)) {
                return provider
            }
        }
        return nil
    }

    /// Whether the token is a leading `NAME=value` environment assignment
    /// (`env FOO=1 cmd`).
    func tmuxHudIsEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        for (offset, character) in token[..<equals].enumerated() {
            guard character.isLetter || character == "_" || (offset > 0 && character.isNumber) else {
                return false
            }
        }
        return true
    }

    func tmuxHudProviderForExecutableName(_ token: String) -> TmuxCompatHudProvider? {
        let name = tmuxHudExecutableName(token)
        return TmuxCompatHudProvider.allCases.first { $0.commandWords.contains(name) }
    }

    /// Reduces a path token to its extensionless basename, so `omp.js`
    /// identifies the omp provider.
    func tmuxHudExecutableName(_ token: String) -> String {
        let base = (token as NSString).lastPathComponent.lowercased()
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else {
            return base
        }
        return String(base[..<dot])
    }

    var tmuxHudInterpreterNames: Set<String> { ["node", "bun", "deno"] }

    func tmuxDebugDiagnosticsEnabled() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return tmuxBooleanValue(environment["CMUX_DEBUG"]) == true
            || tmuxBooleanValue(environment["CMUX_TMUX_DEBUG"]) == true
    }

    func tmuxWriteDebugDiagnostic(_ message: String) {
        guard tmuxDebugDiagnosticsEnabled(),
              let data = "[cmux] \(message)\n".data(using: .utf8) else {
            return
        }
        cliWriteStderr(data)
    }
}
