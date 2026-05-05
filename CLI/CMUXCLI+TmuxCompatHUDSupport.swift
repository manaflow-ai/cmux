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
        if tmuxBooleanValue(dictionary["hudDisabled"]) == true {
            return true
        }
        if tmuxBooleanValue(dictionary["omxHudDisabled"]) == true {
            return true
        }

        let nestedCandidates: [Any?] = [
            dictionary["hud"],
            dictionary["omxHud"],
            dictionary["hudPane"],
            tmuxDictionaryValue(dictionary["omx"])?["hud"]
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

    func tmuxOMXHudConfigDisablesHud(cwd: String?) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if tmuxBooleanValue(environment["OMX_HUD_ENABLED"]) == false
            || tmuxBooleanValue(environment["CMUX_OMX_HUD_ENABLED"]) == false
            || tmuxBooleanValue(environment["OMX_HUD_DISABLED"]) == true
            || tmuxBooleanValue(environment["CMUX_OMX_HUD_DISABLED"]) == true {
            return true
        }

        var candidates: [(URL, Bool)] = []
        let fileManager = FileManager.default
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let cwdURL = URL(fileURLWithPath: resolvePath(cwd), isDirectory: true)
            candidates.append((cwdURL.appendingPathComponent(".omx/hud-config.json"), true))
            candidates.append((cwdURL.appendingPathComponent(".omx/config.json"), false))
            candidates.append((cwdURL.appendingPathComponent(".omx-config.json"), false))
        }

        let homePath = environment["HOME"] ?? NSHomeDirectory()
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
        candidates.append((homeURL.appendingPathComponent(".omx/hud-config.json"), true))
        candidates.append((homeURL.appendingPathComponent(".omx/config.json"), false))
        candidates.append((homeURL.appendingPathComponent(".codex/.omx-config.json"), false))

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

    func tmuxCommandLooksLikeOMXHud(_ commandTokens: [String]) -> Bool {
        let commandText = commandTokens.joined(separator: " ")
        let lowered = commandText.lowercased()
        guard tmuxCommandTextContainsWord(lowered, word: "hud") else {
            return false
        }

        let environment = ProcessInfo.processInfo.environment
        let launchedThroughOMXShim = environment["CMUX_OMX_CMUX_BIN"] != nil
            || environment["CMUX_AGENT_LAUNCH_KIND"] == "omx"
        if launchedThroughOMXShim {
            return true
        }

        return lowered.contains("omx") || lowered.contains("oh-my-codex")
    }

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
        FileHandle.standardError.write(data)
    }
}
