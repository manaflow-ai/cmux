import CryptoKit
import Foundation

/// A parsed `.cmux/env.yaml` environment spec: ordered setup steps that build
/// an environment inside a Cloud VM, plus verify commands that prove it works.
struct VMEnvSpec: Equatable {
    struct Step: Equatable {
        let name: String
        let run: String
        let timeoutMinutes: Int?
    }

    let name: String?
    /// `nil` or `"default"` means the provider's default base image, resolved
    /// server-side so the client hashes against the image the server will boot.
    let base: String?
    let env: [String: String]
    let steps: [Step]
    let verify: [String]
}

struct VMEnvSpecParseError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "env.yaml:\(line): \(message)" }
}

/// Parser for the strict YAML subset used by env specs, and the layer chain
/// hash shared with the backend registry. Kept pure/static so unit tests and
/// the TS mirror (`web/services/vms/envChainHash.ts`) can pin exact vectors.
enum VMEnvSpecCodec {
    // MARK: - Parsing

    static func parse(_ text: String) throws -> VMEnvSpec {
        let rawLines = text.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }

        var version: Int?
        var name: String?
        var base: String?
        var env: [String: String] = [:]
        var steps: [VMEnvSpec.Step] = []
        var verify: [String] = []
        var seenTopLevel = Set<String>()

        var index = 0
        while index < rawLines.count {
            let line = rawLines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            guard indentOf(line) == 0 else {
                throw VMEnvSpecParseError(line: index + 1, message: "unexpected indentation; expected a top-level key")
            }
            guard let (key, rest) = splitKey(line.trimmingCharacters(in: .whitespaces)) else {
                throw VMEnvSpecParseError(line: index + 1, message: "expected `key: value`")
            }
            if seenTopLevel.contains(key) {
                throw VMEnvSpecParseError(line: index + 1, message: "duplicate top-level key `\(key)`")
            }
            seenTopLevel.insert(key)
            switch key {
            case "version":
                guard let value = Int(rest), value == 1 else {
                    throw VMEnvSpecParseError(line: index + 1, message: "`version` must be 1")
                }
                version = value
                index += 1
            case "name":
                name = unquote(rest)
                index += 1
            case "base":
                base = unquote(rest)
                index += 1
            case "env":
                guard rest.isEmpty else {
                    throw VMEnvSpecParseError(line: index + 1, message: "`env` must be a nested map, not an inline value")
                }
                index += 1
                env = try parseEnvMap(rawLines, index: &index)
            case "steps":
                guard rest.isEmpty else {
                    throw VMEnvSpecParseError(line: index + 1, message: "`steps` must be a sequence, not an inline value")
                }
                index += 1
                steps = try parseSteps(rawLines, index: &index)
            case "verify":
                guard rest.isEmpty else {
                    throw VMEnvSpecParseError(line: index + 1, message: "`verify` must be a sequence, not an inline value")
                }
                index += 1
                verify = try parseVerify(rawLines, index: &index)
            default:
                throw VMEnvSpecParseError(line: index + 1, message: "unknown top-level key `\(key)` (allowed: version, name, base, env, steps, verify)")
            }
        }

        guard version != nil else {
            throw VMEnvSpecParseError(line: 1, message: "missing required `version: 1`")
        }
        guard !steps.isEmpty else {
            throw VMEnvSpecParseError(line: 1, message: "spec has no `steps`; add at least one step")
        }
        return VMEnvSpec(name: name, base: base, env: env, steps: steps, verify: verify)
    }

    private static func parseEnvMap(_ lines: [String], index: inout Int) throws -> [String: String] {
        var result: [String: String] = [:]
        var entryIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            let indent = indentOf(line)
            if indent == 0 { break }
            if let expected = entryIndent, indent != expected {
                throw VMEnvSpecParseError(line: index + 1, message: "inconsistent indentation in `env` map")
            }
            entryIndent = entryIndent ?? indent
            guard let (key, rest) = splitKey(line.trimmingCharacters(in: .whitespaces)), !rest.isEmpty else {
                throw VMEnvSpecParseError(line: index + 1, message: "`env` entries must be `KEY: value`")
            }
            if result[key] != nil {
                throw VMEnvSpecParseError(line: index + 1, message: "duplicate env key `\(key)`")
            }
            result[key] = unquote(rest)
            index += 1
        }
        return result
    }

    private static func parseSteps(_ lines: [String], index: inout Int) throws -> [VMEnvSpec.Step] {
        var steps: [VMEnvSpec.Step] = []
        for item in try parseSequenceOfMaps(lines, index: &index, context: "steps") {
            guard let run = item.values["run"], !run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VMEnvSpecParseError(line: item.line, message: "step is missing required `run`")
            }
            let name = item.values["name"].map(unquote) ?? "step \(steps.count + 1)"
            var timeoutMinutes: Int?
            if let rawTimeout = item.values["timeoutMinutes"] {
                guard let parsed = Int(rawTimeout.trimmingCharacters(in: .whitespaces)), parsed > 0 else {
                    throw VMEnvSpecParseError(line: item.line, message: "`timeoutMinutes` must be a positive integer")
                }
                timeoutMinutes = parsed
            }
            if let unknown = item.values.keys.first(where: { !["name", "run", "timeoutMinutes"].contains($0) }) {
                throw VMEnvSpecParseError(line: item.line, message: "unknown step key `\(unknown)` (allowed: name, run, timeoutMinutes)")
            }
            steps.append(VMEnvSpec.Step(name: name, run: normalizeRun(run), timeoutMinutes: timeoutMinutes))
        }
        return steps
    }

    private static func parseVerify(_ lines: [String], index: inout Int) throws -> [String] {
        var commands: [String] = []
        for item in try parseSequenceOfMaps(lines, index: &index, context: "verify") {
            guard let run = item.values["run"], !run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VMEnvSpecParseError(line: item.line, message: "verify entry is missing required `run`")
            }
            if let unknown = item.values.keys.first(where: { $0 != "run" && $0 != "name" }) {
                throw VMEnvSpecParseError(line: item.line, message: "unknown verify key `\(unknown)` (allowed: name, run)")
            }
            commands.append(normalizeRun(run))
        }
        return commands
    }

    private struct SequenceItem {
        let line: Int
        var values: [String: String]
    }

    /// Parses `- key: value` block sequences where each item is a small map.
    /// Values may be plain scalars or `|` block scalars.
    private static func parseSequenceOfMaps(
        _ lines: [String],
        index: inout Int,
        context: String
    ) throws -> [SequenceItem] {
        var items: [SequenceItem] = []
        var itemIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            let indent = indentOf(line)
            if indent == 0 { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if let expected = itemIndent, indent != expected {
                    throw VMEnvSpecParseError(line: index + 1, message: "inconsistent indentation in `\(context)` sequence")
                }
                itemIndent = itemIndent ?? indent
                var item = SequenceItem(line: index + 1, values: [:])
                let keyIndent = indent + 2
                let firstEntry = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                index += 1
                if !firstEntry.isEmpty {
                    try consumeMapEntry(firstEntry, lineNumber: item.line, keyIndent: keyIndent, lines: lines, index: &index, into: &item)
                }
                while index < lines.count {
                    let inner = lines[index]
                    if isBlankOrComment(inner) {
                        index += 1
                        continue
                    }
                    let innerIndent = indentOf(inner)
                    if innerIndent < keyIndent { break }
                    if innerIndent != keyIndent {
                        throw VMEnvSpecParseError(line: index + 1, message: "inconsistent indentation inside `\(context)` item")
                    }
                    let entry = inner.trimmingCharacters(in: .whitespaces)
                    if entry.hasPrefix("- ") {
                        break
                    }
                    let entryLine = index + 1
                    index += 1
                    try consumeMapEntry(entry, lineNumber: entryLine, keyIndent: keyIndent, lines: lines, index: &index, into: &item)
                }
                items.append(item)
            } else {
                throw VMEnvSpecParseError(line: index + 1, message: "expected a `- ` sequence item in `\(context)`")
            }
        }
        return items
    }

    private static func consumeMapEntry(
        _ entry: String,
        lineNumber: Int,
        keyIndent: Int,
        lines: [String],
        index: inout Int,
        into item: inout SequenceItem
    ) throws {
        guard let (key, rest) = splitKey(entry) else {
            throw VMEnvSpecParseError(line: lineNumber, message: "expected `key: value`")
        }
        if item.values[key] != nil {
            throw VMEnvSpecParseError(line: lineNumber, message: "duplicate key `\(key)` in sequence item")
        }
        if rest == "|" || rest == "|-" {
            item.values[key] = try parseBlockScalar(lines, index: &index, parentIndent: keyIndent, lineNumber: lineNumber)
        } else if rest.isEmpty {
            throw VMEnvSpecParseError(line: lineNumber, message: "`\(key)` has no value (use `\(key): <value>` or `\(key): |`)")
        } else {
            item.values[key] = unquote(rest)
        }
    }

    private static func parseBlockScalar(
        _ lines: [String],
        index: inout Int,
        parentIndent: Int,
        lineNumber: Int
    ) throws -> String {
        var collected: [String] = []
        var contentIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                collected.append("")
                index += 1
                continue
            }
            let indent = indentOf(line)
            if indent <= parentIndent { break }
            let effectiveIndent = contentIndent ?? indent
            if indent < effectiveIndent {
                throw VMEnvSpecParseError(line: index + 1, message: "block scalar line is indented less than its first line")
            }
            contentIndent = effectiveIndent
            collected.append(String(line.dropFirst(effectiveIndent)))
            index += 1
        }
        guard contentIndent != nil else {
            throw VMEnvSpecParseError(line: lineNumber, message: "block scalar `|` has no content")
        }
        while collected.last?.isEmpty == true {
            collected.removeLast()
        }
        return collected.joined(separator: "\n")
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func indentOf(_ line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " { count += 1 } else { break }
        }
        return count
    }

    private static func splitKey(_ text: String) -> (key: String, rest: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Trailing whitespace/newlines never change what a step does, but they
    /// would change its chain hash, so strip them before hashing/execution.
    private static func normalizeRun(_ run: String) -> String {
        var result = run
        while let last = result.last, last == "\n" || last == " " || last == "\t" || last == "\r" {
            result.removeLast()
        }
        return result
    }

    // MARK: - Chain hash (mirrored in web/services/vms/envChainHash.ts)

    /// Layer i's chain hash covers the provider, the resolved base image, and
    /// steps 0...i (run text + the spec-global env map). Step names are
    /// excluded so renaming a step does not invalidate its cached snapshot.
    static func chainHashes(provider: String, baseImageId: String, spec: VMEnvSpec) -> [String] {
        var current = sha256Hex("cmux-env-v1\n\(provider)\n\(baseImageId)")
        var hashes: [String] = []
        for step in spec.steps {
            current = sha256Hex(current + "\n" + canonicalStepJSON(run: step.run, env: spec.env))
            hashes.append(current)
        }
        return hashes
    }

    static func specDigest(_ specText: String) -> String {
        sha256Hex(specText)
    }

    /// Deterministic `{"env":{...sorted...},"run":"..."}` serialization written
    /// by hand so Swift and TypeScript produce byte-identical strings
    /// (JSONSerialization escapes `/` and reorders keys; JSON.stringify does not).
    static func canonicalStepJSON(run: String, env: [String: String]) -> String {
        var out = "{\"env\":{"
        let sortedKeys = env.keys.sorted()
        for (offset, key) in sortedKeys.enumerated() {
            if offset > 0 { out += "," }
            out += jsonEscaped(key) + ":" + jsonEscaped(env[key] ?? "")
        }
        out += "},\"run\":" + jsonEscaped(run) + "}"
        return out
    }

    private static func jsonEscaped(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
