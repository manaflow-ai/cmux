import CmuxFuzzSupport
import CmuxNextActions
import CmuxNextAppearance
import CmuxNextDesignTokens
@testable import CmuxNextSettings
import Foundation
import Testing

/// Seeded fuzz of cmux-next.json (plans/cmux-next/chrome-parity/p10-stability.md, task 026): JSONC reads and
/// in-place edits, the snapshot parse of any document (unknown keys, deep nesting, huge numbers, wrong types),
/// keybinding strings and keybindings.json `when` clauses, and the controller's load of a file that turns bad.
/// Chrome fuzzes the same layer (base/json/json_reader_fuzzer.cc) and bounds its nesting (base/json/json_common.h,
/// `kAbsoluteMaxDepth`).
///
/// The properties:
/// - any text parses to a value or throws, never traps; what parses, the writer writes as text that reads back;
/// - nesting deeper than ``JSONC/maxDepth`` is refused, never recursed into, and never written by an edit;
/// - an in-place edit reads back as the same edit of the document's value, and keeps a valid file valid;
/// - any document gives a snapshot, the same one twice, and keys the app does not know change no setting;
/// - a keybinding string reads as a stroke or nil, and a stroke's config string reads back as that stroke;
/// - a `when` clause parses or throws, and one nested past the parser's bound throws;
/// - after a file that does not read (bad JSONC, a root that is not an object, bytes that are not UTF-8, too
///   deep), the settings in effect stay the last good file's.
///
/// The fixed cases of the same limits run on every `swift test`, in ``JSONCLimitTests`` and WhenClauseDepthTests.
///
/// It runs only with `CMUX_SETTINGS_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_SETTINGS_FUZZ=1 swift test --filter SettingsFuzzTests
/// CMUX_SETTINGS_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter SettingsFuzzTests
/// ```
///
/// `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure (CmuxFuzzSupport, p10-stability-016). The suite
/// is serialized, so each of its ``runCount`` runs gets an equal share of a `CMUX_FUZZ_DEADLINE`.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_SETTINGS_FUZZ"] == "1",
        "set CMUX_SETTINGS_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct SettingsFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    nonisolated static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's seeded runs, which share a `CMUX_FUZZ_DEADLINE`.
    nonisolated static let runCount = 7

    /// Each run's share of `CMUX_FUZZ_DEADLINE`, fixed when the first run asks; nil without a deadline or in a replay.
    nonisolated static let deadlineShare: TimeInterval? = {
        guard let environment = try? FuzzEnvironment.current(), environment.iterations == nil,
              let deadline = environment.deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0) / Double(runCount)
    }()

    /// A run of this suite: the process's `CMUX_FUZZ_*` variables, its long mode capped at ``deadlineShare``.
    nonisolated static func run(_ name: String, seed: UInt64, iterations: Int) throws(FuzzError) -> FuzzRun {
        var environment = try FuzzEnvironment.current()
        if let share = deadlineShare { environment.seconds = min(environment.seconds ?? share, share) }
        return FuzzRun(name, seed: seed, iterations: iterations, environment: environment)
    }

    /// One input of the in-process properties, its choices read from `data` (the libFuzzer entry,
    /// p10-stability-182). The controller run writes files and awaits loads, so it is not part of it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(5) {
        case 0: try checkText(rng.bytes(1_024))
        case 1:
            let document = Self.document(&rng)
            try checkSnapshot(document, &rng)
        case 2: try checkKeybinding(&rng)
        case 3: try checkWhenClause(&rng)
        default:
            let document = Self.document(&rng)
            try checkEdit(document, &rng)
        }
    }

    // MARK: - Runs

    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("Settings.oneInput", seed: 0x5E77_0026_0001, iterations: 2_000)
        let tapes: [[UInt8]] = [[0], [1], [2], [3], [1, 9, 2, 200, 7], [3, 4, 4, 1, 0, 9]]
        try run.forEachInput(try run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// Any text, from real files mutated with JSONC tokens, parses or throws; what parses writes back.
    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func anyTextParsesOrThrows() throws {
        let run = try Self.run("Settings.jsonc", seed: 0x5E77_0026_0002, iterations: 20_000)
        try run.forEachInput(try run.corpus(seeds: Self.seedFiles.map { Data($0.utf8) }), mutator: Self.mutator) {
            try Self.checkText($0)
        }
    }

    /// Any document gives a snapshot, the same twice, unknown keys change nothing, and applying it never traps.
    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func anyDocumentGivesASnapshot() throws {
        let applier = SettingsApplier(design: DesignSettings(), registry: .standard())
        try Self.run("Settings.snapshot", seed: 0x5E77_0026_0003, iterations: 1_000).forEach { rng in
            let document = Self.document(&rng)
            try Self.checkSnapshot(document, &rng)
            applier.apply(Self.snapshot(document))
        }
    }

    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func keybindingStringsReadAsStrokesOrNil() throws {
        try Self.run("Settings.keybinding", seed: 0x5E77_0026_0004, iterations: 20_000).forEach { rng in
            try Self.checkKeybinding(&rng)
        }
    }

    /// keybindings.json `when` text, from the clause grammar's tokens and deep `!` and `(` runs, parses or throws.
    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func whenClausesParseOrThrow() throws {
        try Self.run("Settings.when", seed: 0x5E77_0026_0007, iterations: 20_000).forEach { rng in
            try Self.checkWhenClause(&rng)
        }
    }

    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func editsReadBackAndKeepValidFilesValid() throws {
        try Self.run("Settings.edit", seed: 0x5E77_0026_0005, iterations: 5_000).forEach { rng in
            let document = Self.document(&rng)
            try Self.checkEdit(document, &rng)
        }
    }

    /// A sequence of good and bad files through a real ``SettingsController``: every bad one leaves the
    /// last good file's settings in effect. The loads await, so this drives the run's iterations itself.
    @Test(.timeLimit(.minutes(SettingsFuzzTests.timeLimitMinutes)))
    func aBadFileKeepsTheLastGoodSettings() async throws {
        let run = try Self.run("Settings.lastGood", seed: 0x5E77_0026_0006, iterations: 48)
        let deadline = run.environment.longModeBudget(from: Date()).map { ContinuousClock.now.advanced(by: .seconds(min($0, 1e9))) }
        var iteration = 0
        while iteration < run.iterations || deadline.map({ ContinuousClock.now < $0 }) == true {
            var rng = run.generator(for: iteration)
            let files = Self.fileSequence(&rng)
            do {
                try await Self.checkKeepsLastGood(files)
            } catch {
                throw FuzzError.failed(FuzzFailure(
                    name: run.name, seed: run.seed, iteration: iteration, input: nil,
                    reason: String(describing: error), artifact: nil, corpus: run.environment.corpus
                ))
            }
            iteration += 1
        }
    }

    // MARK: - Fixed cases

    /// Every known key set to each extreme number parses and applies without a trap.
    @Test func hugeNumbersInEveryKeyNeverTrap() {
        let applier = SettingsApplier(design: DesignSettings(), registry: .standard())
        for number in Self.hugeNumbers {
            var root = JSONValue.object([:])
            for descriptor in Self.descriptors { root = root.setting(.number(number), at: descriptor.path) }
            applier.apply(Self.snapshot(root))
            let bindings = JSONValue.object(Dictionary(uniqueKeysWithValues: Self.actionIDs.map { ($0, JSONValue.number(number)) }))
            applier.apply(Self.snapshot(.object(["shortcuts": .object(["bindings": bindings])])))
        }
    }
}

// MARK: - Properties

extension SettingsFuzzTests {
    static func checkText(_ data: Data) throws {
        let parsed: JSONValue
        do { parsed = try JSONC.parse(String(decoding: data, as: UTF8.self)) } catch { return }
        try FuzzRun.check(!containsNonFinite(parsed), "a number parsed to a value JSON cannot write: \(parsed)")
        let written = parsed.prettyText()
        do {
            let again = try JSONC.parse(written)
            try FuzzRun.check(same(again, parsed), "the written document reads back as \(again), not \(parsed)")
        } catch let error as FuzzError {
            throw error
        } catch {
            try FuzzRun.check(false, "the writer's text of a parsed document does not parse (\(error)): \(written)")
        }
    }

    static func checkSnapshot(_ document: JSONValue, _ rng: inout FuzzRNG) throws {
        let first = snapshot(document)
        let again = snapshot(document)
        try FuzzRun.check(knownSettings(again) == knownSettings(first) && again.diagnostics == first.diagnostics,
                          "one document parsed to two snapshots: \(document.compactText)")
        guard case .object(var members) = document else { return }
        for _ in 0..<(1 + rng.below(3)) {
            let name = "x-cmux-fuzz-" + rng.text(textAlphabet, 8)
            members[name] = anyValue(&rng, depth: 3)
        }
        let extended = snapshot(.object(members))
        try FuzzRun.check(knownSettings(extended) == knownSettings(first),
                          "keys the app does not know changed a setting: \(JSONValue.object(members).compactText)")
    }

    static func checkKeybinding(_ rng: inout FuzzRNG) throws {
        let text = rng.oneIn(4) ? rng.text(textAlphabet, 16) : strokeText(&rng)
        if let stroke = ShortcutBindingFormat.parseStroke(text) {
            let written = ShortcutBindingFormat.configString(stroke)
            let again = ShortcutBindingFormat.parseStroke(written)
            try FuzzRun.check(again.map(normalized) == normalized(stroke), "\(text) wrote \(written), which reads as \(String(describing: again))")
        }
        let value = bindingValue(&rng)
        let binding = ShortcutBindingFormat.parse(value)
        switch value {
        case .null:
            try FuzzRun.check(binding == ShortcutBinding.unbound, "null did not unbind")
        case .array(let items) where items.count > 2:
            try FuzzRun.check(binding == nil, "\(items.count) strokes read as \(String(describing: binding))")
        case .array(let items) where items.count == 2:
            let strokes = items.compactMap { $0.stringValue.flatMap(ShortcutBindingFormat.parseStroke) }
            let expected = strokes.count == 2 ? ShortcutBinding.chord(strokes[0], strokes[1]) : nil
            try FuzzRun.check(binding == expected, "\(value.compactText) read as \(String(describing: binding))")
        case .string(let token) where ShortcutBindingFormat.unboundTokens.contains(token.trimmingCharacters(in: .whitespaces).lowercased()):
            try FuzzRun.check(binding == ShortcutBinding.unbound, "\(token) did not unbind")
        default:
            break
        }
        let id = rng.element(of: actionIDs) ?? ""
        let dotted = "shortcuts.bindings." + id
        let path = CmuxConfigFile.keyPath(from: dotted)
        if !id.isEmpty, id == id.trimmingCharacters(in: .whitespaces) {
            try FuzzRun.check(path == ["shortcuts", "bindings", id], "\(dotted) split as \(path)")
        }
        _ = CmuxConfigFile.keyPath(from: rng.text(textAlphabet, 24))
    }

    /// A `when` clause parses or throws ``WhenClauseParseError``; one nested past the parser's bound throws.
    static func checkWhenClause(_ rng: inout FuzzRNG) throws {
        var text = (0..<rng.below(24)).map { _ in rng.element(of: whenTokens) ?? "" }.joined(separator: rng.bool() ? " " : "")
        var depth = 0
        if rng.oneIn(6) {
            depth = rng.oneIn(4) ? rng.int(in: 190...210) : rng.int(in: 1...100_000)
            let open = rng.element(of: ["(", "!", "!("]) ?? "("
            let levels = open.count == 2 ? (depth + 1) / 2 : depth
            depth = levels * open.count
            let close = String(repeating: ")", count: open == "!" ? 0 : levels)
            text = String(repeating: open, count: levels) + (text.isEmpty ? "editorFocus" : text) + (rng.bool() ? close : "")
        }
        let parsed = Result<WhenClause, WhenClauseParseError> { () throws(WhenClauseParseError) in try WhenClause.parse(text) }
        if depth > 200, case .success(let clause) = parsed {
            try FuzzRun.check(false, "a clause \(depth) levels deep parsed (\(text.prefix(80))…) as \(String(describing: clause).prefix(80))")
        }
    }

    static func checkEdit(_ document: JSONValue, _ rng: inout FuzzRNG) throws {
        let source = jsoncText(document, &rng)
        let path = editPath(&rng)
        let value = editValue(&rng)
        let expected = document.setting(value, at: path)
        let edited = try JSONC.setting(value, at: path, in: source)
        let read = try JSONC.parse(edited)
        try FuzzRun.check(same(read, expected), "setting \(path) to \(value.compactText) read back as \(read.compactText)\n\(edited)")
        let removed = try JSONC.parse(JSONC.removing(path, in: edited))
        try FuzzRun.check(same(removed, removing(path, from: expected)), "removing \(path) read back as \(removed.compactText)")

        // A valid file a mutation made: an edit throws (one past the nesting limit is refused, never written) or
        // leaves a file that still reads as an object, with the edited value in effect.
        let mutated = String(decoding: mutator.mutate(Data(source.utf8), using: &rng), as: UTF8.self)
        guard (try? JSONC.parse(mutated))?.objectValue != nil,
              let result = try? JSONC.setting(value, at: path, in: mutated) else { return }
        do {
            let read = try JSONC.parse(result)
            try FuzzRun.check(read.objectValue != nil, "an edit left a root that is not an object:\n\(result)")
            try FuzzRun.check(read.value(at: path).map { same($0, value) } == true,
                              "setting \(path) to \(value.compactText) in a mutated file did not take effect:\n\(result)")
        } catch let error as FuzzError {
            throw error
        } catch {
            try FuzzRun.check(false, "an edit broke a valid file (\(error)):\n\(mutated)\n->\n\(result)")
        }
    }

    /// Writes each file in turn and reloads; a file that reads as an object is the new last good one.
    static func checkKeepsLastGood(_ files: [Data]) async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-settings-fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        let design = DesignSettings()
        let registry = ActionRegistry.standard()
        let settings = SettingsController(registry: registry, design: design, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        var lastGood: InEffect?
        for (step, bytes) in files.enumerated() {
            try bytes.write(to: url)
            await settings.reload()
            let now = InEffect(settings, design: design, registry: registry)
            let readsAsObject = (try? JSONC.parse(CmuxConfigFile.source(at: url)))?.objectValue != nil
            if readsAsObject {
                let parsed = try JSONC.parse(CmuxConfigFile.source(at: url))
                try FuzzRun.check(settings.fileRoot == parsed, "step \(step): a good file did not load")
                try FuzzRun.check(!settings.snapshot.diagnostics.contains { $0.kind == .unreadableFile },
                                  "step \(step): a good file was reported unreadable")
                lastGood = now
            } else if let lastGood {
                try FuzzRun.check(settings.snapshot.diagnostics.first?.kind == .unreadableFile,
                                  "step \(step): a bad file was not reported (\(bytes.count) bytes)")
                try FuzzRun.check(now == lastGood, "step \(step): a bad file changed the settings in effect")
            }
        }
    }
}

// MARK: - Inputs

extension SettingsFuzzTests {
    static let descriptors = SettingsSchema.all
    static let knownKeyNames: [String] = Array(Set(SettingsSchema.all.flatMap(\.path))).sorted()
    static let actionIDs: [String] = {
        let catalog = ActionCatalog.all.prefix(40).map(\.id.rawValue)
        return Array(Set(catalog + ["palette.open", "tabGroup.create", "x.fuzz.unknown"])).sorted()
    }()
    /// A configuration folder that does not exist, so no parser reads a file the fuzz names.
    static let noConfigDirectory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-fuzz-none-\(UUID().uuidString)")

    static let textAlphabet: [Character] = [
        "a", "Z", "0", ".", "+", "-", " ", "\"", "\\", "/", "*", "{", "}", "[", "]", ":", ",", "\n", "\t",
        "\u{0}", "\u{1F}", "\u{7F}", "é", "\u{301}", "⌘", "\u{1F600}", "\u{FEFF}",
    ]
    static let hugeNumbers: [Double] = [
        0, -0.0, 1, -1, 0.5, 999_999_999_999_999, 1e15, 1_000_000_000_000_001, 9_007_199_254_740_992,
        2_147_483_648, 4_294_967_296, Double(Int.max), -Double(Int.max), 2 * Double(Int.max), 1e300, -1e300,
        Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude, 1e-300,
    ]
    static let keybindingStrings: [String] = [
        "cmd+shift+p", "cmd++", "+", "++", "ctrl+b", "⌘⇧P", "cmd+⌘", "shift+", "+a", "cmd+opt+ctrl+shift+f20", "f21",
        "f0", "cmd+left", "space", " ", "cmd+ ", "none", " Clear ", "unbound", "disabled", "", "cmd+\u{7F}",
        "cmd+\u{1F600}", "cmd+é", "hyper+a", "cmd+shift+p+q", "cmd+plus", "cmd+equals", "\u{0}",
    ]
    /// The `when` grammar's tokens (WhenClauseParser.swift), with broken ones: lone quotes, slashes and backslashes.
    static let whenTokens: [String] = [
        "!", "(", ")", "&&", "||", "==", "!=", "=~", "/a.b/", "/x\\/y/i", "/open", "in", "not in", "not", "true", "false",
        "editorFocus", "terminal.focused", "pane:kind", "a-b_c", "'quoted value'", "\"dq\"", "1", "1e400", "-2.5", "'", "\"",
        "/", "\\", " ", "\t", "\n", "é", "!!", "((", "))", "&", "|", "=",
    ]
    static let modifierTokens: [String] = [
        "cmd", "command", "⌘", "shift", "⇧", "opt", "option", "alt", "⌥", "ctrl", "control", "ctl", "⌃", "", " Cmd ", "hyper",
    ]
    static let keyTokens: [String] = [
        "a", "Z", "1", "+", "=", ",", "left", "ArrowUp", "tab", "return", "esc", "delete", "space", " ", "f1", "F12", "f20",
        "f21", "pageup", "comma", "plus", "é", "⌘", "\u{7F}", "\u{1F600}", "ab", "",
    ]
    static let jsoncTokens: [String] = [
        "{", "}", "[", "]", "\"", ":", ",", "//", "/*", "*/", "\n", "null", "true", "false", "-0", "1e400", "-1e400",
        "1e308", "9223372036854775808", "18446744073709551616", "0.0000001", "\\u0000", "\\ud800", "\\\"",
        "\"\\u00e9\"", "\"e\\u0301\"", "\"shortcuts\"", "\"bindings\"", "\"appearance\"", "\"density\"",
        "\"cmd+shift+p\"", "[\"ctrl+b\", \"c\"]",
    ]
    /// JSONC tokens, plus a byte order mark, a UTF-16 one and a cut UTF-8 sequence.
    static let mutator = FuzzMutator(
        dictionary: jsoncTokens.map { Data($0.utf8) } + [Data([0xEF, 0xBB, 0xBF]), Data([0xFF, 0xFE]), Data([0xC3])],
        maximumEdits: 6, maximumCount: 1 << 15
    )
    static let seedFiles: [String] = [
        "",
        "// only a comment\n",
        "{}",
        "\u{FEFF}{ \"appearance\": { \"density\": \"compact\", }, }",
        """
        {
          // The person's own file.
          "appearance": { "density": "comfortable", "uiScale": 1.25 },
          "shortcuts": {
            "bindings": { "palette.open": "cmd+shift+p", "tabGroup.create": ["ctrl+b", "c"] },
            "tiers": { "palette.open": "system" },
          },
          /* unknown keys stay */ "x-future": { "nested": [1, 2.5, -3e300, null, true] },
        }
        """,
    ]

    /// A document: known keys with their defaults or any value, shortcut bindings, unknown keys and known
    /// sections of the wrong shape.
    static func document(_ rng: inout FuzzRNG) -> JSONValue {
        var root = JSONValue.object([:])
        for _ in 0..<rng.below(12) {
            switch rng.below(5) {
            case 0:
                if let descriptor = rng.element(of: descriptors), let fallback = descriptor.defaultValue {
                    root = root.setting(fallback, at: descriptor.path)
                }
            case 1:
                if let descriptor = rng.element(of: descriptors) { root = root.setting(anyValue(&rng, depth: 3), at: descriptor.path) }
            case 2:
                let id = rng.element(of: actionIDs) ?? ""
                let path = rng.bool() ? ["shortcuts", "bindings", id] : ["shortcuts", id]
                root = root.setting(bindingValue(&rng), at: path)
            case 3:
                let path = (0...rng.below(3)).map { _ in key(&rng) }
                root = root.setting(anyValue(&rng, depth: 4), at: path)
            default:
                if let head = rng.element(of: descriptors)?.path.first { root = root.setting(anyValue(&rng, depth: 2), at: [head]) }
            }
        }
        return root
    }

    static func anyValue(_ rng: inout FuzzRNG, depth: Int) -> JSONValue {
        switch rng.below(depth > 0 ? 10 : 7) {
        case 0: return .null
        case 1: return .bool(rng.bool())
        case 2: return .number(rng.element(of: hugeNumbers) ?? 0)
        case 3: return .number(rng.double(in: -1e6...1e6))
        case 4: return .number(Double(rng.int(in: -3...300)))
        case 5: return .string(rng.text(textAlphabet, 24))
        case 6: return .string(rng.element(of: keybindingStrings) ?? "")
        case 7: return .array((0..<rng.below(5)).map { _ in anyValue(&rng, depth: depth - 1) })
        default:
            var members: [String: JSONValue] = [:]
            for _ in 0..<rng.below(5) {
                let name = key(&rng)
                members[name] = anyValue(&rng, depth: depth - 1)
            }
            return .object(members)
        }
    }

    static func key(_ rng: inout FuzzRNG) -> String {
        rng.oneIn(3) ? rng.text(textAlphabet, 12) : (rng.element(of: knownKeyNames) ?? "")
    }

    static func strokeText(_ rng: inout FuzzRNG) -> String {
        if rng.oneIn(4) { return rng.element(of: keybindingStrings) ?? "" }
        let modifiers = (0..<rng.below(4)).map { _ in rng.element(of: modifierTokens) ?? "" }
        return (modifiers + [rng.element(of: keyTokens) ?? ""]).joined(separator: "+")
    }

    static func bindingValue(_ rng: inout FuzzRNG) -> JSONValue {
        switch rng.below(6) {
        case 0: return .null
        case 1, 2: return .string(strokeText(&rng))
        case 3: return .array((0..<rng.below(4)).map { _ in JSONValue.string(strokeText(&rng)) })
        case 4:
            var first: [String: JSONValue] = ["key": .string(rng.element(of: keyTokens) ?? "")]
            for flag in ["command", "shift", "option", "control"] where rng.bool() { first[flag] = JSONValue.bool(rng.bool()) }
            var members: [String: JSONValue] = ["first": .object(first)]
            if rng.bool() {
                let second = rng.element(of: keyTokens) ?? ""
                members["second"] = rng.bool() ? JSONValue.null : JSONValue.object(["key": .string(second)])
            }
            return .object(members)
        default: return anyValue(&rng, depth: 2)
        }
    }

    /// The document as a person writes it: pretty, maybe with comments, a trailing comma and a byte order mark.
    static func jsoncText(_ document: JSONValue, _ rng: inout FuzzRNG) -> String {
        var text = document.prettyText()
        if text.hasSuffix("\n}") {
            text.removeLast(2)
            text += rng.bool() ? ",\n}" : " // last\n}"
        }
        if rng.oneIn(3) { text = "// cmux-next.json\n/* fuzz */ " + text }
        if rng.oneIn(4) { text = "\u{FEFF}" + text }
        return text
    }

    static func editPath(_ rng: inout FuzzRNG) -> [String] {
        if rng.bool(), let descriptor = rng.element(of: descriptors) { return descriptor.path }
        return (0...rng.below(3)).map { _ in key(&rng) }
    }

    /// Values the Settings window writes: no extreme numbers, whose text round trip is the reader's business.
    static func editValue(_ rng: inout FuzzRNG) -> JSONValue {
        switch rng.below(5) {
        case 0: return .bool(rng.bool())
        case 1: return .number(Double(rng.int(in: -100...100_000)))
        case 2: return .string(rng.text(textAlphabet, 16))
        case 3: return .null
        default: return .object(["key": .string(rng.text(textAlphabet, 4)), "on": .bool(rng.bool())])
        }
    }

    /// One to seven files after a good one: new documents, mutations of the last file, random bytes, roots that
    /// are not objects, nesting past the limit and empty files.
    static func fileSequence(_ rng: inout FuzzRNG) -> [Data] {
        var files = [Data(jsoncText(document(&rng), &rng).utf8)]
        for _ in 0..<(1 + rng.below(7)) {
            let last = files[files.count - 1]
            switch rng.below(7) {
            case 0: files.append(Data(jsoncText(document(&rng), &rng).utf8))
            case 1, 2: files.append(mutator.mutate(last, using: &rng))
            case 3: files.append(rng.bytes(96))
            case 4: files.append(Data((rng.element(of: ["[]", "1", "\"x\"", "null", "true", "[{}]"]) ?? "[]").utf8))
            case 5:
                let depth = JSONC.maxDepth + 1 + rng.below(50)
                files.append(Data((String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)).utf8))
            default: files.append(Data((rng.element(of: ["", "// nothing yet\n", "  \n", "/* a */"]) ?? "").utf8))
            }
        }
        return files
    }
}

// MARK: - Oracles

extension SettingsFuzzTests {
    /// What a load leaves in effect: the documents, the design values the applier sets and the shortcuts it binds.
    struct InEffect: Equatable {
        var fileRoot: JSONValue
        var effectiveRoot: JSONValue
        var density: DensityTokens
        var uiScale: CGFloat
        var interfaceScale: CGFloat
        var animationSpeed: MotionSpeed
        var modifierHoldHints: Bool
        var inactiveWindowDim: Double
        var shortcuts: [String: Shortcut?]

        @MainActor
        init(_ settings: SettingsController, design: DesignSettings, registry: ActionRegistry) {
            fileRoot = settings.fileRoot
            effectiveRoot = settings.snapshot.root
            density = design.densityTokens
            uiScale = design.uiScale
            interfaceScale = design.interfaceScale
            animationSpeed = design.animationSpeed
            modifierHoldHints = design.showModifierHoldHints
            inactiveWindowDim = design.inactiveWindowDim
            var shortcuts: [String: Shortcut?] = [:]
            for id in SettingsFuzzTests.actionIDs { shortcuts[id] = .some(registry.effectiveShortcut(for: ActionID(rawValue: id))) }
            self.shortcuts = shortcuts
        }
    }

    static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics,
                                 configDirectory: noConfigDirectory)
    }

    /// The settings a snapshot holds, without the document, the reports about it and the background a
    /// shuffle picks by the clock (``BackdropShuffle/pick(on:calendar:fileManager:)``).
    static func knownSettings(_ snapshot: CmuxConfigSnapshot) -> CmuxConfigSnapshot {
        var settings = snapshot
        settings.root = .object([:])
        settings.diagnostics = []
        settings.retiredKeys = []
        settings.backdropSelection = nil
        settings.backdropArt = nil
        return settings
    }

    /// `configString` writes `+` as `plus` and NSDeleteCharacter as `delete`, which read back as `=` and
    /// backspace (``ShortcutBindingFormat/keyEquivalent(forToken:)``): the same physical keys.
    static func normalized(_ stroke: ShortcutStrokeSpec) -> ShortcutStrokeSpec {
        var stroke = stroke
        stroke.key = ["+": "=", "\u{7F}": "\u{8}"][stroke.key] ?? stroke.key
        return stroke
    }

    /// Equal documents, numbers within a relative 1e-12 (a double's text round trip through Foundation).
    static func same(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.number(left), .number(right)):
            return left == right || abs(left - right) <= 1e-12 * max(abs(left), abs(right))
        case let (.array(left), .array(right)):
            return left.count == right.count && zip(left, right).allSatisfy { same($0, $1) }
        case let (.object(left), .object(right)):
            return left.count == right.count && left.allSatisfy { key, value in right[key].map { same(value, $0) } ?? false }
        default:
            return lhs == rhs
        }
    }

    static func containsNonFinite(_ value: JSONValue) -> Bool {
        switch value {
        case .number(let number): !number.isFinite
        case .array(let items): items.contains(where: containsNonFinite)
        case .object(let members): members.values.contains(where: containsNonFinite)
        default: false
        }
    }

    /// `value` without the member at `path`, as ``JSONC/removing(_:in:)`` edits it.
    static func removing(_ path: [String], from value: JSONValue) -> JSONValue {
        guard let head = path.first, case .object(var members) = value, let child = members[head] else { return value }
        members[head] = path.count == 1 ? nil : removing(Array(path.dropFirst()), from: child)
        return .object(members)
    }
}
