import CmuxNextCompat
public import Foundation
import os

/// Reads `~/.config/cmux/cmux-next.json` and sends its writes to the file's one writer, the
/// daemon's settings owner (``SettingsFileWriter``, cmux-tui `cmux-config` `settings.edit`;
/// plans/cmux-next/settings-react.md section 1). An actor so file IO and parsing stay off the main
/// actor and writes go out in call order. The owner edits the JSONC source in place (comments and
/// unknown keys survive) and publishes atomically; the file watcher then reloads and applies the
/// change, so there is one path from disk to live settings.
///
/// With no writer, or one that cannot reach the daemon, a write throws
/// ``SettingsWriterDisconnected`` and writes nothing; nothing queues.
public actor CmuxConfigFile {
    public nonisolated let url: URL
    /// Keys an MDM profile or the team policy manages; every write checks it.
    public nonisolated let managedGuard: ManagedKeyGuard
    /// Where writes go; nil refuses every write.
    public nonisolated let writer: (any SettingsFileWriter)?
    /// The last write sent, which the next one waits for.
    private var lastWrite: Task<[Int], any Error>?

    public init(url: URL, managedGuard: ManagedKeyGuard = ManagedKeyGuard(), writer: (any SettingsFileWriter)? = nil) {
        self.url = url
        self.managedGuard = managedGuard
        self.writer = writer
    }

    /// The conventional location, `<home>/.config/cmux/cmux-next.json`, unless
    /// `CMUX_NEXT_CONFIG_FILE` names another file. The override keeps test
    /// launches of tagged builds from reading or writing the user's file
    /// (`home` is the account's home, which ignores `$HOME`).
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment[overrideKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appending(path: ".config/cmux/cmux-next.json")
    }

    /// Returns the next config URL and seeds it once from classic cmux's
    /// `cmux.json` when the next file does not exist. An explicit override is
    /// returned unchanged and is never seeded from the user's files.
    ///
    /// The caller supplies the home and file manager so first-launch behavior
    /// is deterministic in tests and never depends on `$HOME`.
    public static func prepareDefaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        try prepareLaunchFile(home: home, environment: environment, fileManager: fileManager).url
    }

    /// The settings file at launch and whether this launch made it from nothing: no cmux-next.json and
    /// no classic cmux.json, on this Mac account. Every channel shares the file, so that is the one
    /// install-wide sign of a fresh install (a new channel on an existing install finds the file).
    public nonisolated struct LaunchFile: Sendable {
        public let url: URL
        public let createdEmpty: Bool
    }

    /// ``prepareDefaultURL(home:environment:fileManager:)``, saying whether it wrote a new empty file.
    public static func prepareLaunchFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> LaunchFile {
        if let override = environment[overrideKey], !override.isEmpty {
            return LaunchFile(url: defaultURL(home: home, environment: environment), createdEmpty: false)
        }

        let next = defaultURL(home: home, environment: environment)
        guard !fileManager.fileExists(atPath: next.path) else { return LaunchFile(url: next, createdEmpty: false) }
        var createdEmpty = false

        let classic = next.deletingLastPathComponent().appendingPathComponent("cmux.json")
        try fileManager.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if fileManager.fileExists(atPath: classic.path) {
                // Its text, never the file: a classic cmux.json symlinked into a
                // dotfiles repo would otherwise become next's file too, and next's
                // settings migration would rewrite classic's settings through it.
                // concurrency-allow: first-launch seeding, as the copy it replaces; the file is small.
                let text = try Data(contentsOf: classic.resolvingSymlinksInPath())
                try text.write(to: next, options: .withoutOverwriting)
            } else {
                try Data("{}\n".utf8).write(to: next, options: .withoutOverwriting)
                createdEmpty = true
            }
        } catch CocoaError.fileWriteFileExists {
            // Another cmux-next launch won the first-launch race. Keep its file.
        }
        return LaunchFile(url: next, createdEmpty: createdEmpty)
    }

    /// The app's settings file at launch: ``prepareDefaultURL(home:environment:fileManager:)``, or
    /// when that fails, the reason in the log and ``defaultURL(home:environment:)``.
    public static func launchURL() -> URL { launchFile().url }

    /// ``launchURL()`` and whether this launch made the file from nothing (``LaunchFile``).
    public static func launchFile() -> LaunchFile {
        do {
            return try prepareLaunchFile()
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app")
                .error("cmux-next config bootstrap failed: \(String(describing: error), privacy: .public)")
            return LaunchFile(url: defaultURL(), createdEmpty: false)
        }
    }

    /// Environment variable that replaces the settings file path.
    public static let overrideKey = "CMUX_NEXT_CONFIG_FILE"

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case unreadable(String)
        case invalidPath(String)

        public var description: String {
            switch self {
            case .unreadable(let message): "cmux-next.json is not valid JSONC: \(message)"
            case .invalidPath(let path): "invalid settings path '\(path)'"
            }
        }
    }

    /// The raw source text, or "" when the file does not exist.
    public func source() throws -> String {
        try Self.source(at: url)
    }

    /// The file's text at `url` on the calling thread (the launch's first
    /// load); a missing file is empty.
    public nonisolated static func source(at url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        }
    }

    /// Writes `text` beside the file as `<file name>.<suffix>` (the record a launch migration keeps
    /// of what it changed, so the person can see and undo it). Read back only to undo a change a
    /// later build no longer makes (``readBeside(suffix:)``).
    @discardableResult
    public func writeBeside(suffix: String, text: String) throws -> URL {
        let url = self.url.resolvingSymlinksInPath()
        let record = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(suffix)")
        try Data(text.utf8).blockingWrite(to: record, options: .atomic)
        return record
    }

    /// Whether ``writeBeside(suffix:text:)`` left a record named `suffix` beside the file (a regular
    /// file; a folder of that name is not one).
    public func hasRecordBeside(suffix: String) -> Bool {
        let url = self.url.resolvingSymlinksInPath()
        let record = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(suffix)")
        var isDirectory: ObjCBool = false
        return FileManager.checked.fileExists(atPath: record.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The text of the record named `suffix` beside the file, or nil when there is none.
    public func readBeside(suffix: String) -> String? {
        let url = self.url.resolvingSymlinksInPath()
        let record = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(suffix)")
        return try? String(blockingContentsOf: record, encoding: .utf8)
    }

    /// Sets each path the file leaves unset to its value, in one publish; a path set since the
    /// caller read it keeps its value (`set_unset`, checked by the writer on the file it
    /// publishes). Returns the paths set.
    public func setUnset(_ values: [(path: [String], value: JSONValue)]) async throws -> [[String]] {
        guard values.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        let root = try document()
        for entry in values where root.value(at: entry.path) == nil { try managedGuard.checkSet(entry.value, at: entry.path) }
        let applied = try await send(values.map { .setUnset($0.path, $0.value) })
        return applied.map { values[$0].path }
    }

    /// The parsed document. A missing file is an empty object.
    public func document() throws -> JSONValue {
        try validated(try source())
    }

    /// The value at `path`, or nil when absent. An empty path is the root.
    public func value(at path: [String]) throws -> JSONValue? {
        try document().value(at: path)
    }

    /// Sets `path` to `value`.
    public func set(_ value: JSONValue, at path: [String]) async throws {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        try managedGuard.checkSet(value, at: path)
        _ = try document()
        _ = try await send([.set(path, value)])
    }

    /// Removes the member at `path`. No-op when absent.
    public func remove(_ path: [String]) async throws {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        try managedGuard.checkRemove(path)
        _ = try document()
        _ = try await send([.reset(path)])
    }

    /// Sets (a value) or removes (nil) several paths in one publish, so the watcher never applies a
    /// half-done edit.
    public func apply(_ edits: [(path: [String], value: JSONValue?)]) async throws {
        guard edits.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        for edit in edits {
            if let value = edit.value { try managedGuard.checkSet(value, at: edit.path) } else { try managedGuard.checkRemove(edit.path) }
        }
        _ = try document()
        _ = try await send(edits.map { edit -> SettingsFileEdit in
            if let value = edit.value { .set(edit.path, value) } else { .reset(edit.path) }
        })
    }

    /// Sends `edits` as they are, in one publish; each one passes the managed guard first. Returns
    /// the indexes of the edits that applied.
    @discardableResult
    public func edit(_ edits: [SettingsFileEdit]) async throws -> [Int] {
        guard edits.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        for edit in edits {
            switch edit {
            case .set(let path, let value), .setUnset(let path, let value): try managedGuard.checkSet(value, at: path)
            case .reset(let path), .resetUnchanged(let path, _): try managedGuard.checkRemove(path)
            }
        }
        _ = try document()
        return try await send(edits)
    }

    /// Removes each path whose value is still `expected`, in one publish; the writer checks each
    /// value on the file it publishes (`reset_unchanged`), so a path changed since stays.
    /// With `recordBeside`, `record(removed, before)` is written beside the file first
    /// (`writeBeside`) for the paths whose value matches now, so a failed record write leaves the
    /// file as it was. Returns the removed paths and the text the removals were read from.
    public func removeUnchanged(
        _ expected: [(path: [String], value: JSONValue)],
        recordBeside suffix: String? = nil,
        record: @Sendable (_ removed: [[String]], _ before: String) throws -> String = { _, _ in "" }
    ) async throws -> (removed: [[String]], before: String) {
        guard expected.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        let current = try source()
        let root = try validated(current)
        let matching = expected.filter { root.value(at: $0.path) == $0.value }
        for entry in matching { try managedGuard.checkRemove(entry.path) }
        guard !matching.isEmpty else { return ([], current) }
        if let suffix { try writeBeside(suffix: suffix, text: record(matching.map(\.path), current)) }
        let applied = try await send(matching.map { .resetUnchanged($0.path, $0.value) })
        return (applied.map { matching[$0].path }, current)
    }

    private func validated(_ text: String) throws -> JSONValue {
        do {
            return try JSONC.parse(text)
        } catch {
            // Never rewrite a file the user left broken: they would lose it.
            throw Failure.unreadable(JSONC.problem(error, in: text))
        }
    }

    /// Sends `edits` to the writer after every write this actor sent before, so writes publish in
    /// call order (a slider's burst keeps its last value).
    private func send(_ edits: [SettingsFileEdit]) async throws -> [Int] {
        guard let writer else { throw SettingsWriterDisconnected() }
        let previous = lastWrite
        let url = self.url
        // task-owner: one settings write, chained after the previous one so writes publish in call order
        let write = Task {
            _ = await previous?.result
            return try await writer.edit(edits, file: url)
        }
        lastWrite = write
        return try await write.value
    }

    // MARK: - Key paths

    /// Splits a dotted settings path. Action IDs contain dots
    /// (`tabGroup.create`), so everything after `shortcuts.bindings.`,
    /// `shortcuts.when.`, or a direct `shortcuts.` action key is one key.
    /// Callers that need other dotted keys pass an array path instead.
    public static func keyPath(from dotted: String) -> [String] {
        let trimmed = dotted.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        for prefix in ["shortcuts.bindings.", "shortcuts.when."] where trimmed.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count))
            return prefix.split(separator: ".").map(String.init) + (rest.isEmpty ? [] : [rest])
        }
        if trimmed.hasPrefix("shortcuts.") {
            let rest = String(trimmed.dropFirst("shortcuts.".count))
            let head = rest.split(separator: ".", maxSplits: 1).first.map(String.init) ?? rest
            if CmuxConfigSnapshot.reservedShortcutKeys.contains(head) {
                return ["shortcuts"] + rest.split(separator: ".").map(String.init)
            }
            return ["shortcuts", rest]
        }
        return trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }
}
