/// Reads the literal, top-level assignments from a WezTerm config without running Lua.
///
/// Understood: `config.key = <literal>` (for a `local config = wezterm.config_builder()`
/// or `local config = {}`), `return { key = <literal>, ... }`, and literal
/// tables, strings, numbers, booleans and `wezterm.font(...)` calls. Anything
/// computed (variables, concatenation, function calls, assignments inside
/// `if`/`for`/functions) is reported as skipped rather than guessed.
struct LuaStaticConfigReader {
    struct Result: Equatable {
        /// Literal assignments by config key, last one wins.
        var values: [String: LuaValue] = [:]
        /// Keys whose value is computed in Lua.
        var computedKeys: [String] = []
        /// Keys assigned inside functions, conditionals or loops.
        var conditionalKeys: [String] = []
    }

    private static let blockOpeners: Set<String> = ["function", "if", "do", "repeat"]
    private static let blockClosers: Set<String> = ["end", "until"]

    func read(_ source: String) -> Result {
        let tokens = LuaTokenizer().tokens(in: source)
        var result = Result()
        var configNames: Set<String> = []
        var depth = 0
        var index = 0

        func token(_ offset: Int) -> LuaToken? {
            let position = index + offset
            return position < tokens.count ? tokens[position] : nil
        }

        while index < tokens.count {
            let current = tokens[index]
            if current.kind == .name, Self.blockOpeners.contains(current.text) {
                depth += 1
                index += 1
                continue
            }
            if current.kind == .name, Self.blockClosers.contains(current.text) {
                depth = max(0, depth - 1)
                index += 1
                continue
            }

            if depth == 0, current.kind == .name, current.text == "local",
               let name = token(1), name.kind == .name, token(2)?.text == "=" {
                let isBuilder = token(3)?.text == "wezterm" && token(4)?.text == "." && token(5)?.text == "config_builder"
                let isEmptyTable = token(3)?.text == "{" && token(4)?.text == "}"
                if isBuilder || isEmptyTable {
                    configNames.insert(name.text)
                }
                index += 3
                continue
            }

            if depth == 0, current.kind == .name, current.text == "return", token(1)?.text == "{" {
                var position = index + 1
                if case .table(let entries)? = parseValue(tokens, &position) {
                    for entry in entries {
                        if let key = entry.key { result.values[key] = entry.value }
                    }
                    index = position
                    continue
                }
            }

            let isConfigName = configNames.contains(current.text) || (configNames.isEmpty && current.text == "config")
            if current.kind == .name, isConfigName, token(1)?.text == ".",
               let key = token(2), key.kind == .name, token(3)?.text == "=" {
                var position = index + 4
                let value = parseValue(tokens, &position)
                if depth > 0 {
                    result.conditionalKeys.append(key.text)
                } else if let value, !continuesExpression(tokens, position) {
                    result.values[key.text] = value
                    index = position
                    continue
                } else {
                    result.computedKeys.append(key.text)
                }
                index = skipStatement(tokens, from: index + 4, startLine: current.line)
                continue
            }
            index += 1
        }
        return result
    }

    private func continuesExpression(_ tokens: [LuaToken], _ position: Int) -> Bool {
        guard position < tokens.count else { return false }
        let next = tokens[position]
        return next.kind == .symbol && ["..", "+", "-", "*", "/", "(", ".", "[", ":", "or", "and"].contains(next.text)
            || (next.kind == .name && ["or", "and"].contains(next.text))
    }

    /// Skips a computed value: balanced brackets and blocks, then to the next line.
    private func skipStatement(_ tokens: [LuaToken], from start: Int, startLine: Int) -> Int {
        var position = start
        var balance = 0
        while position < tokens.count {
            let token = tokens[position]
            if balance == 0, token.line != startLine, position > start {
                let previous = tokens[position - 1]
                let previousContinues = previous.kind == .symbol && ["..", "+", "-", "*", "/", ",", "(", "{", "["].contains(previous.text)
                if !previousContinues { break }
            }
            if token.kind == .symbol, ["{", "(", "["].contains(token.text) { balance += 1 }
            if token.kind == .symbol, ["}", ")", "]"].contains(token.text) { balance -= 1 }
            if token.kind == .name, Self.blockOpeners.contains(token.text) { balance += 1 }
            if token.kind == .name, Self.blockClosers.contains(token.text) { balance -= 1 }
            position += 1
        }
        return position
    }

    /// Parses a literal starting at `position`, leaving `position` after it; `nil` if it is not a literal.
    private func parseValue(_ tokens: [LuaToken], _ position: inout Int) -> LuaValue? {
        guard position < tokens.count else { return nil }
        let token = tokens[position]
        switch token.kind {
        case .string:
            position += 1
            return .string(token.text)
        case .number:
            position += 1
            return number(token.text).map { .number($0) }
        case .symbol where token.text == "-":
            position += 1
            guard position < tokens.count, tokens[position].kind == .number,
                  let value = number(tokens[position].text) else { return nil }
            position += 1
            return .number(-value)
        case .symbol where token.text == "{":
            return parseTable(tokens, &position)
        case .name where token.text == "true" || token.text == "false":
            position += 1
            return .bool(token.text == "true")
        case .name where token.text == "wezterm":
            return parseFontCall(tokens, &position)
        default:
            return nil
        }
    }

    private func parseTable(_ tokens: [LuaToken], _ position: inout Int) -> LuaValue? {
        position += 1
        var entries: [LuaValue.Entry] = []
        while position < tokens.count {
            let token = tokens[position]
            if token.text == "}" {
                position += 1
                return .table(entries)
            }
            if token.text == "," || token.text == ";" {
                position += 1
                continue
            }
            var key: String?
            if token.kind == .name, position + 1 < tokens.count, tokens[position + 1].text == "=" {
                key = token.text
                position += 2
            } else if token.text == "[", position + 3 < tokens.count,
                      tokens[position + 1].kind == .string, tokens[position + 2].text == "]",
                      tokens[position + 3].text == "=" {
                key = tokens[position + 1].text
                position += 4
            }
            guard let value = parseValue(tokens, &position), !continuesExpression(tokens, position) else {
                return nil
            }
            entries.append(.init(key: key, value: value))
        }
        return nil
    }

    /// `wezterm.font("X", ...)`, `wezterm.font "X"`, `wezterm.font { family = "X" }`,
    /// `wezterm.font_with_fallback({ "X", ... })`: the first family.
    private func parseFontCall(_ tokens: [LuaToken], _ position: inout Int) -> LuaValue? {
        guard position + 2 < tokens.count, tokens[position + 1].text == ".",
              ["font", "font_with_fallback"].contains(tokens[position + 2].text) else { return nil }
        var cursor = position + 3
        guard cursor < tokens.count else { return nil }
        var argument: LuaValue?
        if tokens[cursor].text == "(" {
            cursor += 1
            argument = parseValue(tokens, &cursor)
            // Skip remaining arguments, which may be literal attribute tables.
            var balance = 1
            while cursor < tokens.count, balance > 0 {
                if tokens[cursor].text == "(" { balance += 1 }
                if tokens[cursor].text == ")" { balance -= 1 }
                cursor += 1
            }
        } else {
            argument = parseValue(tokens, &cursor)
        }
        guard let family = Self.family(from: argument) else { return nil }
        position = cursor
        return .font(family)
    }

    private static func family(from value: LuaValue?) -> String? {
        switch value {
        case .string(let name)?:
            return name
        case .table?:
            if let family = value?["family"]?.string { return family }
            return family(from: value?.positional.first)
        default:
            return nil
        }
    }

    private func number(_ text: String) -> Double? {
        if text.lowercased().hasPrefix("0x") {
            return Int(text.dropFirst(2), radix: 16).map(Double.init)
        }
        return ConfigValue.decimal(text)
    }
}
