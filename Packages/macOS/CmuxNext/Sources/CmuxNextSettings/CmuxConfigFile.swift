import CmuxNextCompat
public import Foundation
import os

/// Reads and writes `~/.config/cmux/cmux-next.json`. An actor so file IO and
/// parsing stay off the main actor and writes are serialized. Writes edit
/// the JSONC source in place (comments and unknown keys survive) and
/// publish atomically; the file watcher then reloads and applies them, so
/// there is one path from disk to live settings.
///
/// The daemon writes the same file (`settings.set`, `settings.reset`). Every write here holds the
/// daemon's lock (``SettingsFileLock``) from its read of the file to its publish, so a daemon
/// write and a write here never replace each other's edit. A write suspends while it waits for
/// the lock (never a thread of the caller's), and throws ``SettingsFileBusy`` when another
/// writer keeps the lock too long. Other calls of this actor may run during that wait; each write
/// reads the file only after it has the lock.
public actor CmuxConfigFile {
    public nonisolated let url: URL
    /// Keys an MDM profile or the team policy manages; every write checks it.
    public nonisolated let managedGuard: ManagedKeyGuard

    public init(url: URL, managedGuard: ManagedKeyGuard = ManagedKeyGuard()) {
        self.url = url
        self.managedGuard = managedGuard
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

    /// Sets each path the file leaves unset to its value, in one atomic publish; a path set since
    /// the caller read it keeps its value. Read and write share one actor turn and one hold of the
    /// settings lock. Returns the paths set.
    public func setUnset(_ values: [(path: [String], value: JSONValue)]) async throws -> [[String]] {
        guard values.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        let lock = try await SettingsFileLock.acquire(file: url)
        defer { lock.release() }
        let current = try source()
        let root = try validated(current)
        let unset = values.filter { root.value(at: $0.path) == nil }
        for entry in unset { try managedGuard.checkSet(entry.value, at: entry.path) }
        var updated = current
        for entry in unset { updated = try JSONC.setting(entry.value, at: entry.path, in: updated) }
        if updated != current { try publish(updated) }
        return unset.map(\.path)
    }

    /// The parsed document. A missing file is an empty object.
    public func document() throws -> JSONValue {
        let text = try source()
        do {
            return try JSONC.parse(text)
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
    }

    /// The value at `path`, or nil when absent. An empty path is the root.
    public func value(at path: [String]) throws -> JSONValue? {
        try document().value(at: path)
    }

    /// Sets `path` to `value` and publishes the file atomically.
    public func set(_ value: JSONValue, at path: [String]) async throws {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        try managedGuard.checkSet(value, at: path)
        let lock = try await SettingsFileLock.acquire(file: url)
        defer { lock.release() }
        let current = try source()
        _ = try validated(current)
        try publish(try JSONC.setting(value, at: path, in: current))
    }

    /// Removes the member at `path`. No-op when absent.
    public func remove(_ path: [String]) async throws {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        try managedGuard.checkRemove(path)
        let lock = try await SettingsFileLock.acquire(file: url)
        defer { lock.release() }
        let current = try source()
        _ = try validated(current)
        let updated = try JSONC.removing(path, in: current)
        if updated != current { try publish(updated) }
    }

    /// Removes the object at `path` when it has no members. The check and the removal share one
    /// actor turn and one hold of the settings lock, so an object that gains a member meanwhile
    /// (a daemon write, or another write here) stays. True when removed.
    func removeEmptyObject(at path: [String]) async throws -> Bool {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        let lock = try await SettingsFileLock.acquire(file: url)
        defer { lock.release() }
        let current = try source()
        guard case .object(let members)? = try validated(current).value(at: path), members.isEmpty else { return false }
        try managedGuard.checkRemove(path)
        try publish(try JSONC.removing(path, in: current))
        return true
    }

    /// Sets (a value) or removes (nil) several paths in one atomic publish,
    /// so the watcher never applies a half-done edit.
    public func apply(_ edits: [(path: [String], value: JSONValue?)]) async throws {
        guard edits.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        for edit in edits {
            if let value = edit.value { try managedGuard.checkSet(value, at: edit.path) } else { try managedGuard.checkRemove(edit.path) }
        }
        let lock = try await SettingsFileLock.acquire(file: url)
        defer { lock.release() }
        let current = try source()
        _ = try validated(current)
        var updated = current
        for edit in edits {
            if let value = edit.value {
                updated = try JSONC.setting(value, at: edit.path, in: updated)
            } else {
                updated = try JSONC.removing(edit.path, in: updated)
            }
        }
        if updated != current { try publish(updated) }
    }

    /// Removes each path whose value is still `expected` in the file as it is now, then each object
    /// those removals emptied, in one atomic publish; a path changed since the caller read it stays.
    /// Read and write share one actor turn and one hold of the settings lock, so no other write of
    /// this file, here or in the daemon, lands between them.
    /// With `recordBeside`, `record(removed, before)` is written beside the file first
    /// (`writeBeside`), so a failed record write leaves the file as it was. Returns the removed
    /// paths and the text before the publish.
    public func removeUnchanged(
        _ expected: [(path: [String], value: JSONValue)],
        recordBeside suffix: String? = nil,
        record: @Sendable (_ removed: [[String]], _ before: String) throws -> String = { _, _ in "" }
    ) async throws -> (removed: [[String]], before: String) {
        guard expected.allSatisfy({ !$0.path.isEmpty }) else { throw Failure.invalidPath("") }
        let lock = try await SettingsFileLock.acquire(file: url)
        defer { lock.release() }
        let current = try source()
        let root = try validated(current)
        let removed = expected.filter { root.value(at: $0.path) == $0.value }.map(\.path)
        for path in removed { try managedGuard.checkRemove(path) }
        var updated = current
        for path in removed { updated = try JSONC.removing(path, in: updated) }
        // Deepest first, so an object a removal empties goes before its parent is checked.
        for parent in Set(removed.flatMap { path in (1..<path.count).map { Array(path.prefix($0)) } })
            .sorted(by: { $0.count > $1.count }) {
            if case .object(let members)? = try JSONC.parse(updated).value(at: parent), members.isEmpty {
                updated = try JSONC.removing(parent, in: updated)
            }
        }
        if updated != current {
            if let suffix { try writeBeside(suffix: suffix, text: record(removed, current)) }
            try publish(updated)
        }
        return (removed, current)
    }

    private func validated(_ text: String) throws -> JSONValue {
        do {
            return try JSONC.parse(text)
        } catch {
            // Never rewrite a file the user left broken: they would lose it.
            throw Failure.unreadable(String(describing: error))
        }
    }

    private func publish(_ text: String) throws {
        // Write through a symlinked cmux-next.json (dotfile repos) instead of
        // replacing the link with a regular file.
        let url = self.url.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
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
