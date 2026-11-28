import Foundation

extension AgentLaunchEnvironmentPolicy {
    /// Environment updates that undo a cmux Claude launch's NODE_OPTIONS
    /// injection inherited by a long-lived process such as the app itself.
    ///
    /// A cmux Claude launch prepends a `--require` restore preload to
    /// NODE_OPTIONS and records the original value in `CMUX_ORIGINAL_NODE_OPTIONS*`.
    /// A process started from inside that session (for example cmux relaunched
    /// from an agent shell) inherits the preload path and passes it to every
    /// terminal it spawns, so `node` fails everywhere once the file is gone (#22274).
    ///
    /// Returns an empty dictionary when nothing needs to change. A `nil` value
    /// means the key should be unset.
    public func inheritedNodeOptionsRepair(from env: [String: String]) -> [String: String?] {
        var updates: [String: String?] = [:]
        if let nodeOptions = env["NODE_OPTIONS"], containsCmuxNodeOptionsRestoreModule(nodeOptions) {
            updates["NODE_OPTIONS"] = .some(selectedNodeOptions(from: env))
        }
        for key in ["CMUX_ORIGINAL_NODE_OPTIONS", "CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"] where env[key] != nil {
            updates[key] = .some(nil)
        }
        return updates
    }

    func selectedNodeOptions(from env: [String: String]) -> String? {
        let marker = env["CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch marker?.isEmpty == false ? marker : nil {
        case "1":
            return sanitizedNodeOptions(env["CMUX_ORIGINAL_NODE_OPTIONS"])
        case "0":
            return nil
        default:
            return sanitizedNodeOptions(env["NODE_OPTIONS"])
        }
    }

    /// One NODE_OPTIONS argument: `value` is what Node sees after unquoting,
    /// `raw` is the original text, kept so re-serialization preserves quoting.
    private struct NodeOptionsToken {
        var value: String
        var raw: String
    }

    /// Tokenizes NODE_OPTIONS the way Node does (ParseNodeOptionsEnvVar):
    /// whitespace separates arguments, double quotes group text containing
    /// whitespace and are stripped from the value, and inside quotes a
    /// backslash makes the next character literal. Unterminated quotes and a
    /// trailing backslash are handled leniently rather than rejected.
    private func nodeOptionsTokens(_ rawValue: String) -> [NodeOptionsToken] {
        var tokens: [NodeOptionsToken] = []
        var current: NodeOptionsToken?
        var isInString = false
        var isEscaped = false
        for character in rawValue {
            if isEscaped {
                current?.value.append(character)
                current?.raw.append(character)
                isEscaped = false
                continue
            }
            if !isInString, character.isWhitespace {
                if let token = current {
                    tokens.append(token)
                    current = nil
                }
                continue
            }
            if current == nil {
                current = NodeOptionsToken(value: "", raw: "")
            }
            current?.raw.append(character)
            if isInString, character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInString.toggle()
            } else {
                current?.value.append(character)
            }
        }
        if isEscaped {
            current?.value.append("\\")
        }
        if let token = current {
            tokens.append(token)
        }
        return tokens
    }

    func sanitizedNodeOptions(_ rawValue: String?) -> String? {
        let parsed = nodeOptionsTokens(rawValue ?? "")
        guard !parsed.isEmpty else { return nil }
        let tokens = parsed.map(\.value)

        var sanitized: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, isInjectedNodeHeapCap(tokens, index: index) {
                index += nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if isRequireOption(token), index + 1 < tokens.count,
               isCmuxNodeOptionsRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = inlineRequireOptionPath(token),
               isCmuxNodeOptionsRestoreModulePath(path) {
                index += 1
                shouldDropInjectedHeapCap = true
                continue
            }

            sanitized.append(parsed[index].raw)
            index += 1
        }

        let joined = sanitized.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func containsCmuxNodeOptionsRestoreModule(_ rawValue: String) -> Bool {
        let tokens = nodeOptionsTokens(rawValue).map(\.value)
        return tokens.indices.contains { index in
            let token = tokens[index]
            if let path = inlineRequireOptionPath(token) {
                return isCmuxNodeOptionsRestoreModulePath(path)
            }
            return isRequireOption(token) && index + 1 < tokens.count
                && isCmuxNodeOptionsRestoreModulePath(tokens[index + 1])
        }
    }

    private func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    private func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    private func isCmuxNodeOptionsRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard URL(fileURLWithPath: trimmed).lastPathComponent == "restore-node-options.cjs" else {
            return false
        }
        return trimmed.contains("/cmux-")
    }

    private func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size" {
            return index + 1 < tokens.count && tokens[index + 1] == "4096"
        }
        return token == "--max-old-space-size=4096"
    }

    private func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count else { return 1 }
        return tokens[index] == "--max-old-space-size" ? min(2, tokens.count - index) : 1
    }
}
