import CmuxNextHomeModel
import Foundation
import Testing

/// Every home rules op the app's Swift names exists in the linked cmux-app-ffi.
///
/// An op the library does not know answers `CMUX_HOME_ERR_UNKNOWN_OP`: debug builds stop on it
/// (the rule wrappers assert) and release builds silently answer a fallback. Launch reaches such
/// ops: Home's Chief tab asked for `chiefs_tab` without its `cloud.` area, and the app stopped at
/// launch. So this reads every op name the CmuxNext sources pass to a home rules caller, puts
/// before it the area that caller's own body adds (read from the wrapper, never assumed here),
/// and checks the full name against `ops.list` of the library the tests link: a wrong name, a
/// wrapper that drops its area or a pin that predates the op fails here, before any launch.
@Suite struct HomeRulesOpNamesTests {
    /// A caller of the home rules: how a call names its op, and the wrapper whose body says what
    /// it puts before that name (nil: `HomeRules` itself, which adds nothing).
    struct Caller {
        /// Matches the call up to its first argument's opening quote.
        var call: String
        /// Matches the wrapper's declaration line.
        var declaration: String?
    }

    static let callers: [Caller] = [
        Caller(call: #"\bHomeRules\.call(?:JSON)?\("#, declaration: nil),
        Caller(call: #"\bHomeEngineRules\.call\("#, declaration: #"struct HomeEngineRules\b"#),
        Caller(call: #"\bwelcomeRule\("#, declaration: #"func welcomeRule<"#),
        Caller(call: #"\bdockRule\("#, declaration: #"func dockRule<"#),
        Caller(call: #"\bHomeChiefRenameFailure\.ruled\("#, declaration: #"static func ruled\("#),
        Caller(call: #"\bChiefHomeRules\(\)\.call(?:JSON)?\("#, declaration: #"struct ChiefHomeRules\b"#),
        Caller(call: #"\bHomeComposeRules\(\)\.call\("#, declaration: #"struct HomeComposeRules\b"#),
        Caller(call: #"\bmappingRule\("#, declaration: #"func mappingRule<"#),
        Caller(call: #"\bChiefRules\.(?:rule|call)\("#, declaration: #"enum ChiefRules\b"#),
    ]

    /// The files that call the home rules with a name they were given (a wrapper). A new wrapper
    /// goes here and into ``callers``, so the names its callers pass are checked.
    static let wrappers: Set<String> = [
        "CmuxNextChiefPetWiring/WelcomeRule.swift",
        "CmuxNextChiefViews/WelcomeRule.swift",
        "CmuxNextHomeEngine/ChiefHome.swift",
        "CmuxNextHomeEngine/DockRule.swift",
        "CmuxNextHomeEngine/HomeChiefNames.swift",
        "CmuxNextHomeEngine/HomeCoreMapping+Rules.swift",
        "CmuxNextHomeEngine/WelcomeRule.swift",
        "CmuxNextHomeModel/Conversations/HomeComposeRules.swift",
        "CmuxNextHomeModel/WelcomeRule.swift",
        "CmuxNextHostedChief/HostedChiefRules.swift",
    ]

    /// A call that hands the home rules a name it was given: `HomeRules.call(op`, `"area." + name`
    /// or `"area.\(name)"`. Group 1 is the callee, group 2 or 3 the area it adds.
    static let forward = #"\b(HomeRules|HomeEngineRules)\.call(?:JSON)?\(\s*(?:"([a-z_]+\.)"\s*\+\s*|"([a-z_]+\.)\\\()?[a-z]\w*"#

    /// The literal first argument of a call (no interpolation, followed by `,` or `)`).
    static let literal = #"\s*"([^"\\]+)"\s*[,)]"#

    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// Each Swift file under Sources, by its path below Sources.
    static func swiftFiles() throws -> [(path: String, text: String)] {
        let root = sources.standardizedFileURL.path + "/"
        guard let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        var files: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            files.append((String(url.standardizedFileURL.path.dropFirst(root.count)), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// Each match's groups (empty string for a group that did not take part).
    static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    /// The text of the declaration `declaration` matches: its line to the `}` at its indent.
    static func body(of declaration: String, in text: String) throws -> String? {
        let lines = text.components(separatedBy: "\n")
        let regex = try NSRegularExpression(pattern: declaration)
        guard let start = lines.firstIndex(where: { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else { return nil }
        let indent = String(lines[start].prefix { $0 == " " })
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix(indent + "}") } ?? lines.count - 1
        return lines[start...end].joined(separator: "\n")
    }

    /// What `caller` puts before the names it is given, read from its declarations (each module
    /// that declares one); nil when no declaration forwards a name to the home rules.
    static func areas(of caller: Caller, in files: [(path: String, text: String)]) throws -> Set<String>? {
        guard let declaration = caller.declaration else { return [""] }
        var areas: Set<String> = []
        for file in files {
            guard let body = try body(of: declaration, in: file.text) else { continue }
            for groups in try matches(forward, in: body) {
                let own = groups[2] + groups[3]
                let callee = groups[1] == "HomeRules" ? [""] : try Self.areas(of: callers[1], in: files) ?? []
                areas.formUnion(callee.map { own + $0 })
            }
        }
        return areas.isEmpty ? nil : areas
    }

    @Test func everyOpTheAppNamesIsInTheLinkedRules() throws {
        let known = Set(try HomeRules.call("ops.list", HomeRules.Empty()) as [String])
        let files = try Self.swiftFiles()
        var named: [String: Set<String>] = [:]
        for caller in Self.callers {
            let areas = try #require(try Self.areas(of: caller, in: files), "no declaration of \(caller.call) forwards a name to the home rules")
            #expect(areas.count == 1, "\(caller.call) adds different areas in different modules: \(areas.sorted())")
            for file in files {
                for groups in try Self.matches(caller.call + Self.literal, in: file.text) {
                    for area in areas { named[area + groups[1], default: []].insert(file.path) }
                }
            }
        }
        // The scan reads the callers it should: Home's Chief tab rule is one of them.
        #expect(named.keys.contains { $0.hasSuffix("chiefs_tab") }, "the scan found no ChiefRules call in \(Self.sources.path)")
        #expect(named.count > 100, "the scan found only \(named.count) op names")
        let unknown = named.keys.filter { !known.contains($0) }.sorted()
        let report = unknown.map { "\($0) (\(named[$0, default: []].sorted().joined(separator: ", ")))" }.joined(separator: "; ")
        #expect(unknown.isEmpty, "ops the linked home rules do not know: \(report)")
    }

    @Test func everyWrapperIsChecked() throws {
        // A call whose name is not one literal: a wrapper passing its caller's name through.
        let passThrough = #"\b(?:HomeRules\.call(?:JSON)?|HomeEngineRules\.call)\((?!\s*"[^"\\]+"\s*[,)])"#
        var found: Set<String> = []
        for file in try Self.swiftFiles() {
            if try !Self.matches(passThrough, in: file.text).isEmpty { found.insert(file.path) }
        }
        let unregistered = found.subtracting(Self.wrappers).sorted()
        #expect(unregistered.isEmpty, "home rules wrappers whose op names nothing checks (add each to callers and wrappers): \(unregistered)")
    }
}
