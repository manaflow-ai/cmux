import CmuxNextCompat
public import CmuxNextFiles
public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The Agent Board page (webviews/src/pages/agent-board): every agent's work-tracking ledger
    /// (`skills/work-tracking/SKILL.md`) in one place, read from this Mac's ledger folder.
    static let agentBoard = PageDescriptor(id: "cmux.agent-board", resource: "agent-board", namespaces: ["cmux.agentBoard."])
}

/// The Agent Board's owner side. The ledgers are JSONL files agents append to in the ledger folder
/// (`CMUX_AGENT_BOARD_DIR`, else `~/.cmux/agent-board`); the page folds them (`ledger.ts`).
///
/// - `cmux.agentBoard.state` -> `{enabled, folder, ledgers: [{file, modifiedMs, text, truncated}]}`:
///   the newest ``ledgerLimit`` ledgers, each up to ``ledgerByteLimit`` bytes, read off the main actor.
/// - `cmux.agentBoard.setEnabled {on}`: writes `agents.board.enabled` as the person; refused
///   without the person's click or key, since it changes what every new agent session is given.
/// - `cmux.agentBoard.evidence {path}` -> `{dataURL}` or `{tooLarge}`: an image a ledger names,
///   up to ``imageByteLimit``. A path no ledger names is refused, so the page cannot read other files.
/// - `cmux.agentBoard.open {path}` or `{url}`: opens a file or an https link a ledger names
///   (person only).
/// - stream `cmux.agentBoard.changes`: one empty event per change in the folder (FSEvents, no polling).
@MainActor
public final class AgentBoardPageProvider: PageProvider {
    public static let ledgerLimit = 200
    public static let ledgerByteLimit = 2 * 1024 * 1024
    public static let imageByteLimit = 12 * 1024 * 1024
    static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    ]

    private let folder: URL
    private let enabled: @MainActor () -> Bool
    private let write: @MainActor (Bool) async throws -> Void
    private let openFile: @MainActor (URL) -> Void
    private let openLink: @MainActor (URL) -> Bool
    private let watcher: any FolderWatching

    public init(
        folder: URL = AgentBoardPageProvider.defaultFolder(),
        enabled: @escaping @MainActor () -> Bool,
        write: @escaping @MainActor (Bool) async throws -> Void,
        openFile: @escaping @MainActor (URL) -> Void,
        openLink: @escaping @MainActor (URL) -> Bool,
        watcher: any FolderWatching = FolderWatcher()
    ) {
        self.folder = folder
        self.enabled = enabled
        self.write = write
        self.openFile = openFile
        self.openLink = openLink
        self.watcher = watcher
    }

    /// The provider the app uses: `agents.board.enabled` read from and written to `settings` as the
    /// person (a `.userOnly` key), files opened by the app and links in a cmux browser tab.
    public convenience init(
        settings: SettingsController?,
        openFile: @escaping @MainActor (URL) -> Void,
        openLink: @escaping @MainActor (URL) -> Bool
    ) {
        self.init(
            enabled: { [weak settings] in settings.map { Self.isEnabled($0.snapshot.root) } ?? false },
            write: { [weak settings] on in
                guard let settings else {
                    throw PageError(code: "cmux.agentBoard.unavailable", message: Self.settingsNotLoaded, retryable: true)
                }
                try await settings.setSetting(at: AgentGuidanceSettings.boardEnabledPath, to: .bool(on), by: .user)
            },
            openFile: openFile,
            openLink: openLink)
    }

    /// Whether the settings file turns the board on; the flat dotted key counts as the nested one.
    public nonisolated static func isEnabled(_ root: JSONValue) -> Bool {
        (root["agents.board.enabled"] ?? root.value(at: AgentGuidanceSettings.boardEnabledPath))?.boolValue == true
    }

    /// The ledger folder agents write to: the skill's `CMUX_AGENT_BOARD_DIR`, else `~/.cmux/agent-board`.
    public nonisolated static func defaultFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CMUX_AGENT_BOARD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmux/agent-board", isDirectory: true)
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.agentBoard.state":
            let folder = self.folder
            let ledgers = await Task.detached(priority: .userInitiated) { Self.readLedgers(in: folder) }.value
            return .object([
                "enabled": .bool(enabled()),
                "folder": .string(folder.path),
                "ledgers": .array(ledgers.map(\.json)),
            ])
        case "cmux.agentBoard.setEnabled":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: Self.personOnly)
            }
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            try await write(on)
            return .object(["enabled": .bool(on)])
        case "cmux.agentBoard.evidence":
            guard let path = params["path"]?.stringValue, !path.isEmpty else { throw PageError.invalidParams("path is required") }
            let folder = self.folder
            let image = try await Task.detached(priority: .userInitiated) { try Self.readImage(path, in: folder) }.value
            return image
        case "cmux.agentBoard.open":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: Self.personOnly)
            }
            let target = params["url"]?.stringValue ?? params["path"]?.stringValue ?? ""
            guard !target.isEmpty else { throw PageError.invalidParams("path or url is required") }
            let folder = self.folder
            let link = URL(string: target).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
            let file = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            let (named, exists) = await Task.detached(priority: .userInitiated) {
                (Self.ledgersName(target, in: folder), link != nil || FileManager.checked.fileExists(atPath: file.path))
            }.value
            guard named else { throw Self.notInLedger }
            if let link { return .object(["opened": .bool(openLink(link))]) }
            guard exists else { throw PageError(code: "cmux.agentBoard.missing", message: Self.missing) }
            openFile(file)
            return .object(["opened": .bool(true)])
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.agentBoard.changes" else { throw PageError.unknownOp(stream) }
        // The folder must exist for FSEvents to watch it; agents create it on their first append too.
        let folder = self.folder
        await Task.detached(priority: .utility) {
            try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
        }.value
        let changes = watcher.changes(in: folder)
        // main-hop-allow: one empty page event per folder change; FSEvents coalesces bursts (50 ms) and the
        // stream keeps at most 64 changes, so each hop only posts one message to the page's web view.
        let task = Task { @MainActor in
            for await _ in changes { onEvent(.object([:])) }
        }
        return PageSubscription { task.cancel() }
    }

    // MARK: - Reading (off the main actor)

    struct Ledger: Sendable {
        var file: String
        var modified: Date
        var text: String
        var truncated: Bool
        var json: JSONValue {
            .object([
                "file": .string(file),
                "modifiedMs": .number((modified.timeIntervalSince1970 * 1000).rounded()),
                "text": .string(text),
                "truncated": .bool(truncated),
            ])
        }
    }

    /// The newest ledgers in `folder` (`*.jsonl`), newest first. A missing folder is no ledgers.
    nonisolated static func readLedgers(in folder: URL) -> [Ledger] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
            return []
        }
        let files = items.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jsonl",
                  let values = try? url.blockingResourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        return files.sorted { $0.1 > $1.1 }.prefix(ledgerLimit).compactMap { url, modified in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.blockingRead(upToCount: ledgerByteLimit + 1)) ?? Data()
            let truncated = data.count > ledgerByteLimit
            let kept = truncated ? data.prefix(ledgerByteLimit) : data
            // A cut line at the end is dropped rather than shown as an unreadable line.
            var text = String(decoding: kept, as: UTF8.self)
            if truncated, let lastBreak = text.lastIndex(of: "\n") { text = String(text[..<lastBreak]) }
            return Ledger(file: url.lastPathComponent, modified: modified, text: text, truncated: truncated)
        }
    }

    /// Whether any ledger in `folder` names `target`, as the JSON string a ledger line holds.
    nonisolated static func ledgersName(_ target: String, in folder: URL) -> Bool {
        guard let encoded = try? JSONEncoder().encode(target), let quoted = String(data: encoded, encoding: .utf8) else {
            return false
        }
        // JSONEncoder escapes "/" as "\/"; agents write it plain. Accept either spelling.
        let plain = quoted.replacingOccurrences(of: "\\/", with: "/")
        return readLedgers(in: folder).contains { $0.text.contains(plain) || $0.text.contains(quoted) }
    }

    nonisolated static func readImage(_ path: String, in folder: URL) throws -> JSONValue {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let type = imageTypes[file.pathExtension.lowercased()] else {
            throw PageError(code: "cmux.agentBoard.notImage", message: notImage)
        }
        guard ledgersName(path, in: folder) else { throw notInLedger }
        let attributes = try? FileManager.checked.attributesOfItem(atPath: file.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue else {
            throw PageError(code: "cmux.agentBoard.missing", message: missing)
        }
        if size > imageByteLimit { return .object(["tooLarge": .bool(true), "size": .number(Double(size))]) }
        guard let data = try? Data(blockingContentsOf: file) else {
            throw PageError(code: "cmux.agentBoard.missing", message: missing)
        }
        return .object(["dataURL": .string("data:\(type);base64,\(data.base64EncodedString())")])
    }

    // MARK: - Strings

    /// The tab's title.
    public static var title: String { t("agentBoard.tab.title", "Agent Board") }

    /// Why a switch did nothing: the settings file has not loaded yet.
    public nonisolated static var settingsNotLoaded: String {
        t("agentBoard.error.settingsNotLoaded", "Settings are still loading. Try again in a moment.")
    }

    nonisolated static var personOnly: String {
        t("agentBoard.error.personOnly", "Only you can do this, with a click or key in the page.")
    }

    nonisolated static var notInLedger: PageError {
        PageError(code: "cmux.agentBoard.notInLedger", message: t("agentBoard.error.notInLedger", "No agent ledger names this file or link."))
    }

    nonisolated static var missing: String {
        t("agentBoard.error.missing", "The file is gone: it was moved or deleted after the agent recorded it.")
    }

    nonisolated static var notImage: String {
        t("agentBoard.error.notImage", "Only images can be shown here. Open the file instead.")
    }

    private nonisolated static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
