import Foundation

/// Stateless parser for sidebar-metadata and sidebar-mutation control-socket commands.
///
/// All methods are pure transforms over the raw argument string: shell-like
/// tokenization, `--key[=value]` option parsing, metadata-format token parsing,
/// option-value normalization, and `--tab`/`--panel` target parsing. The parser
/// holds no state and reaches no app singletons; resolving a parsed target to a
/// concrete tab is the caller's job. Behavior is byte-identical to the legacy
/// `TerminalController` parsers it replaces, so the control-socket wire format is
/// preserved exactly.
public struct SidebarMetadataArgumentParser: Sendable {
    /// Creates a parser. The parser is stateless; a fresh instance is cheap.
    public init() {}

    /// Splits a raw argument string into tokens using shell-like quoting.
    ///
    /// Single and double quotes group tokens; inside double quotes, the escapes
    /// `\n`, `\r`, `\t`, `\"`, `\'`, and `\\` are interpreted. Unescaped
    /// whitespace separates tokens. Empty input yields no tokens.
    /// - Parameter args: The raw argument string.
    /// - Returns: The parsed tokens in order.
    public func tokenize(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Parses `--key[=value]` options and positional arguments, stopping option
    /// parsing at a bare `--` (everything after is positional).
    ///
    /// `--key value` consumes the next token as the value unless that token
    /// starts with `--`, in which case the option's value is the empty string.
    /// - Parameter args: The raw argument string.
    /// - Returns: The positional arguments and the option dictionary.
    public func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenize(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    /// Parses `--key[=value]` options and positional arguments, treating a bare
    /// `--` as a no-op separator that is dropped rather than a stop marker.
    ///
    /// Tokens after a `--` continue to be parsed as options. Used by commands
    /// whose value text may itself contain `--`.
    /// - Parameter args: The raw argument string.
    /// - Returns: The positional arguments and the option dictionary.
    public func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenize(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    /// Parses a metadata-format token into a ``SidebarMetadataFormat``.
    ///
    /// Accepts `plain`, `markdown`, and the `md` alias (case-insensitive).
    /// - Parameter raw: The raw format token.
    /// - Returns: The format, or `nil` for an unknown token.
    public func parseMetadataFormat(_ raw: String) -> SidebarMetadataFormat? {
        switch raw.lowercased() {
        case "plain":
            return .plain
        case "markdown", "md":
            return .markdown
        default:
            return nil
        }
    }

    /// Normalizes an optional option value: trims whitespace and maps an empty
    /// result to `nil`.
    /// - Parameter value: The raw option value, or `nil`.
    /// - Returns: The trimmed non-empty value, or `nil`.
    public func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses the `--tab` option into a ``SidebarMutationTabTargetResolution``.
    ///
    /// Absent `--tab` resolves to ``SidebarMutationTabTarget/selected``. A UUID
    /// resolves to ``SidebarMutationTabTarget/workspace(_:)``; a non-negative
    /// integer resolves to ``SidebarMutationTabTarget/index(_:)``; anything else
    /// (including an empty value) yields the verbatim `ERROR: Tab not found`.
    /// - Parameter options: The parsed option dictionary.
    /// - Returns: The resolution carrying a target or an error.
    public func parseMutationTabTarget(
        options: [String: String]
    ) -> SidebarMutationTabTargetResolution {
        if let rawTabArg = options["tab"] {
            let tabArg = rawTabArg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tabArg.isEmpty else {
                return SidebarMutationTabTargetResolution(target: nil, error: "ERROR: Tab not found")
            }
            if let tabId = UUID(uuidString: tabArg) {
                return SidebarMutationTabTargetResolution(target: .workspace(tabId), error: nil)
            }
            if let index = Int(tabArg), index >= 0 {
                return SidebarMutationTabTargetResolution(target: .index(index), error: nil)
            }
            return SidebarMutationTabTargetResolution(target: nil, error: "ERROR: Tab not found")
        }
        return SidebarMutationTabTargetResolution(target: .selected, error: nil)
    }

    /// Parses the optional `--panel`/`--surface` id option.
    ///
    /// `--surface` is honored as an alias when `--panel` is absent. An empty value
    /// yields `ERROR: Missing panel id — usage: <usage>`; a non-UUID value yields
    /// `ERROR: Invalid panel id '<raw>'`; an absent option yields a `nil` id with no
    /// error. Error strings are returned verbatim to preserve the legacy responses.
    /// - Parameters:
    ///   - options: The parsed option dictionary.
    ///   - usage: The usage string interpolated into the missing-id error.
    /// - Returns: The parsed panel id or a verbatim error.
    public func parseOptionalPanelId(
        options: [String: String],
        usage: String
    ) -> SidebarOptionalPanelId {
        guard let rawPanelArg = options["panel"] ?? options["surface"] else {
            return SidebarOptionalPanelId(panelId: nil, error: nil)
        }
        let panelArg = rawPanelArg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else {
            return SidebarOptionalPanelId(panelId: nil, error: "ERROR: Missing panel id — usage: \(usage)")
        }
        guard let panelId = UUID(uuidString: panelArg) else {
            return SidebarOptionalPanelId(panelId: nil, error: "ERROR: Invalid panel id '\(rawPanelArg)'")
        }
        return SidebarOptionalPanelId(panelId: panelId, error: nil)
    }

    /// Splits a metadata-block argument string at the first ` -- ` separator into
    /// an options part and an optional trailing markdown part.
    /// - Parameter args: The raw argument string.
    /// - Returns: The options substring and the markdown substring (`nil` if no
    ///   separator was present).
    public func splitMetadataBlockArgs(_ args: String) -> (optionsPart: String, markdownPart: String?) {
        guard let separatorRange = args.range(of: " -- ") else {
            return (args, nil)
        }
        let optionsPart = String(args[..<separatorRange.lowerBound])
        let markdownPart = String(args[separatorRange.upperBound...])
        return (optionsPart, markdownPart)
    }
}
