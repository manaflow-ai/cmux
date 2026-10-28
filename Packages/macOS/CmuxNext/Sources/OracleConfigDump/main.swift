import CmuxNextActions
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

// The app side of the oracle's config suite: reads every file of
// tests/oracle/corpus/config the way the app does (`JSONC`, `EffectiveSettings.merge`,
// `SettingDescriptor`, `ShortcutBindingFormat`, `WhenClause.allowsBareKeys`) and prints one JSONL
// dump line per file. cmux-config's `oracle_effective` example prints the same lines for the
// daemon; `scripts/cmux-next/oracle/gen_config.py diff` compares them. The line format is in
// gen_config.py's docstring. An executable, not a test target (p15-oracle.md, 2026-10-10 ruling).
//
// swift run --package-path Packages/macOS/CmuxNext OracleConfigDump --corpus DIR [--out FILE]

/// One merge's inputs: the cmux.json text and the managed layers.
struct DumpInputs {
    var text: String
    var managed = ManagedPreferences()
    var team = TeamPolicyLayer()
}

/// The dump itself, with no I/O. Main actor because the `when` parser (CmuxNextActions) is.
@MainActor
struct OracleConfigDump {
    /// The JSONL text: the header line, then one line per source.
    func render(_ sources: [CorpusSource]) throws(DumpError) -> String {
        var text = Self.line(.object(["oracle_config_dump": .number(1), "producer": .string("swift")]))
        for source in sources {
            let record = try dump(file: source.file, text: source.text)
            text += Self.line(.object(["file": .string(source.file), "dump": record]))
        }
        return text
    }

    func dump(file: String, text: String) throws(DumpError) -> JSONValue {
        switch file.split(separator: "/").first.map(String.init) ?? "" {
        case "keybindings": return try keybindingsDump(file: file, text: text)
        case "managed": return settingsDump(try envelope(file: file, text: text))
        default: return settingsDump(DumpInputs(text: text))
        }
    }

    func envelope(file: String, text: String) throws(DumpError) -> DumpInputs {
        let root: JSONValue
        do {
            root = try JSONValue.parse(Data(text.utf8))
        } catch {
            throw .envelope(file: file, reason: String(describing: error))
        }
        guard let fileText = root["file"]?.stringValue else { throw .envelope(file: file, reason: "\"file\" must be a string") }
        let team = root["team"]
        return DumpInputs(
            text: fileText,
            managed: ManagedPreferences(forced: root["forced"]?.objectValue ?? [:], recommended: root["recommended"]?.objectValue ?? [:]),
            team: TeamPolicyLayer(teamName: team?["name"]?.stringValue ?? "", defaults: team?["defaults"]?.objectValue ?? [:],
                                  enforced: team?["enforced"]?.objectValue ?? [:])
        )
    }

    /// What the app applies for `inputs`; an unreadable file applies as an empty one (a fresh launch
    /// has no last good document).
    func settingsDump(_ inputs: DumpInputs) -> JSONValue {
        let parsed = (try? JSONC.parse(inputs.text)).flatMap { $0.objectValue == nil ? nil : $0 }
        let fileRoot = parsed ?? .object([:])
        let effective = EffectiveSettings.merge(file: fileRoot, managed: inputs.managed, team: inputs.team)
        var values: [String: JSONValue] = [:]
        var invalid: [JSONValue] = []
        for row in SettingsSchema.all {
            guard let stored = effective.root.value(at: row.path) else { continue }
            values[row.id] = row.effectiveValue(in: effective.root) ?? .null
            if !row.accepts(stored) { invalid.append(.string(row.id)) }
        }
        let retired = SettingsSchema.retiredKeys.keys.sorted()
            .filter { fileRoot.value(at: $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init)) != nil }
        let managed = effective.managedKeys.mapValues { source -> JSONValue in
            switch source {
            case .device: .string("mdm")
            case .team(let name): .string("team:\(name)")
            }
        }
        let diagnostics: [JSONValue] = effective.diagnostics.compactMap { diagnostic -> JSONValue? in
            let kind: String
            switch diagnostic.kind {
            case .managedOverride: kind = "managed_override"
            case .managedConflict: kind = "managed_conflict"
            default: return nil
            }
            return .object(["kind": .string(kind), "path": .string(diagnostic.path), "message": .string(diagnostic.message)])
        }
        return .object([
            "readable": .bool(parsed != nil),
            "effective": effective.root,
            "values": .object(values),
            "invalid": .array(invalid),
            "retired": .array(retired.map(JSONValue.string)),
            "managed": .object(managed),
            "policy": .object(effective.policy),
            "diagnostics": .array(diagnostics),
        ])
    }

    func keybindingsDump(file: String, text: String) throws(DumpError) -> JSONValue {
        let root: JSONValue
        do {
            root = try JSONValue.parse(Data(text.utf8))
        } catch {
            throw .envelope(file: file, reason: String(describing: error))
        }
        func texts(_ name: String) -> [String] { root[name]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        let strokes: [JSONValue] = texts("strokes").map { text -> JSONValue in
            guard let stroke = ShortcutBindingFormat.parseStroke(text) else { return .null }
            return .object(["key": .string(stroke.key), "cmd": .bool(stroke.command), "shift": .bool(stroke.shift),
                            "opt": .bool(stroke.option), "ctrl": .bool(stroke.control)])
        }
        let bareWhen: [JSONValue] = texts("when").map { text -> JSONValue in
            .bool((try? WhenClause.parse(text))?.allowsBareKeys ?? false)
        }
        return .object(["strokes": .array(strokes), "bare_when": .array(bareWhen)])
    }

    /// One JSONL line. A non-finite number (no JSON spelling) becomes a marked string, so the
    /// line still parses and the diff shows it.
    static func line(_ value: JSONValue) -> String {
        finite(value).compactText + "\n"
    }

    static func finite(_ value: JSONValue) -> JSONValue {
        switch value {
        case .number(let number) where !number.isFinite: .string("non-finite:\(number)")
        case .array(let items): .array(items.map(finite))
        case .object(let members): .object(members.mapValues(finite))
        default: value
        }
    }
}

/// The composition root: makes the one BackgroundWork the run's file I/O goes through and returns the
/// exit status (0, or 2 on bad arguments or an unreadable corpus).
@MainActor
func runDump(arguments: [String]) async -> Int32 {
    let work = BackgroundWork(cpuWidth: 1, label: "com.cmuxterm.next.oracle-config-dump")
    var status: Int32 = 0
    do throws(DumpError) {
        let files = CorpusFiles(options: try DumpOptions(arguments: arguments), work: work)
        let sources = try await files.read()
        try await files.write(try OracleConfigDump().render(sources))
    } catch {
        FileHandle.standardError.write(Data("OracleConfigDump: \(error)\n".utf8))
        status = 2
    }
    await work.shutdown()
    return status
}

exit(await runDump(arguments: CommandLine.arguments))
