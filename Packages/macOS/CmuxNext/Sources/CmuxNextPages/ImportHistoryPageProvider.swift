public import AppKit
import CmuxNextChiefMemory
import CmuxNextCompat
public import CmuxNextSettings
import Foundation
import UniformTypeIdentifiers

/// Native capabilities for the import page. Paths are admitted only by detection, a file-panel
/// choice or a temporary paste file. A real Import click grants the following async CLI calls.
@MainActor
public final class ImportHistoryPageProvider: PageProvider {
    public typealias Run = @MainActor ([String], Duration) async throws -> JSONValue
    private let command: MemoryImportCommand
    private let run: Run
    private let personOnlyMessage: String
    private var admitted: [String: String] = [:]
    private var temporaryFolders: [URL] = []
    private var batch: String?
    private var nativeBatch: String?
    private var busy = false
    private var spentGesture: TimeInterval?
    public var anchor: () -> NSWindow? = { nil }
    public var restart: () -> Void = {}
    public var finish: (Bool) -> Void = { _ in }

    public init(muxHome: String, personOnlyMessage: String, run: @escaping Run) {
        command = MemoryImportCommand(target: .local(muxHome: muxHome))
        self.run = run
        self.personOnlyMessage = personOnlyMessage
    }

    nonisolated deinit {
        let folders = temporaryFolders
        // task-owner: removes only this provider's private paste files after the page releases it
        Task.detached(priority: .utility) {
            for folder in folders { try? FileManager.checked.removeItem(at: folder) }
        }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.importHistory.detect":
            // Passive page detection must stay TCC-safe. Export folders are scanned only after
            // the person clicks Find exports in the open import page.
            let includesExports = params["exports"]?.boolValue == true
            if includesExports { try requireGesture(context) }
            let result = try await run(command.detect(exports: includesExports), .seconds(60))
            let sources = (result["sources"]?.arrayValue ?? []).filter { source in
                includesExports || !(source["source"]?.stringValue ?? "").hasPrefix("zip:")
            }
            for source in sources {
                if let name = source["source"]?.stringValue {
                    // Presence hints for no-export assistants are already text sources;
                    // preserve their origin so the page can import the admitted path.
                    let kind = source["kind"]?.stringValue ?? ""
                    admitted[name] = ["grok-bot", "muse", "dots", "instinct"].contains(kind) ? kind : ""
                }
            }
            return ["sources": .array(sources.map { source in
                ["source": source["source"] ?? .null, "kind": source["kind"] ?? .null,
                 "path": source["path"] ?? .null, "items": source["count"] ?? .null,
                 "bytes": source["bytes"] ?? .null]
            })]
        case "cmux.importHistory.begin":
            try requireGesture(context)
            guard !busy, let id = params["batch"]?.stringValue, !id.isEmpty else {
                throw PageError.invalidParams("an idle import and batch are required")
            }
            guard batch == nil || batch == id else {
                throw PageError.invalidParams("undo or finish the current batch before starting another")
            }
            if batch == nil { nativeBatch = UUID().uuidString.lowercased() }
            batch = id
            return [:]
        case "cmux.importHistory.pickZip":
            try requireGesture(context)
            guard !busy else { throw PageError.invalidParams("import is running") }
            #if DEBUG
            // A fleet journey may answer this picker with its own synthetic export.
            // The native click and all later batch/source checks still apply.
            if let fixture = ProcessInfo.processInfo.environment["CMUX_NEXT_IMPORT_HISTORY_TEST_ZIP"] {
                let url = try Self.debugFixtureZip(fixture, home: FileManager.default.homeDirectoryForCurrentUser)
                return admitZip(url)
            }
            #endif
            let panel = NSOpenPanel()
            panel.message = ChiefMemoryImportStrings.choosePrompt
            panel.allowedContentTypes = [.zip]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            let response = await withCheckedContinuation { done in
                if let window = anchor() {
                    panel.beginSheetModal(for: window) { done.resume(returning: $0) }
                } else {
                    panel.begin { done.resume(returning: $0) }
                }
            }
            guard response == .OK, let url = panel.url else { return .null }
            return admitZip(url)
        case "cmux.importHistory.prepareText":
            guard batch != nil, !busy, let text = params["text"]?.stringValue,
                  let origin = params["summaryOrigin"]?.stringValue,
                  ["grok-bot", "muse", "dots", "instinct"].contains(origin) else {
                throw PageError.invalidParams("begin an import and supply text with a supported origin")
            }
            let (folder, file) = try await Self.pasteFile(text)
            temporaryFolders.append(folder)
            let source = "text:" + file.path
            admitted[source] = origin
            return ["source": .string(source)]
        case "cmux.importHistory.dryRun", "cmux.importHistory.write":
            guard !busy, let batch, let nativeBatch, params["batch"]?.stringValue == batch,
                  let source = params["source"]?.stringValue, let origin = admitted[source],
                  (params["summaryOrigin"]?.stringValue ?? "") == origin else {
                throw PageError.invalidParams("source and batch must belong to this import")
            }
            busy = true
            defer { busy = false }
            let writing = op == "cmux.importHistory.write"
            var arguments = writing ? command.write(source, batch: nativeBatch) : command.dryRun(source)
            if !origin.isEmpty { arguments += ["--origin", origin] }
            defer { if writing { restart() } }
            if writing { return try await completeTransaction(arguments, timeout: .seconds(3600)) }
            return try await run(arguments, .seconds(600))
        case "cmux.importHistory.undo":
            try requireGesture(context)
            guard !busy, let batch, let nativeBatch, params["batch"]?.stringValue == batch else {
                throw PageError.invalidParams("batch must belong to this import")
            }
            busy = true
            defer { busy = false; restart() }
            let result = try await completeTransaction(command.undo() + ["--batch", nativeBatch], timeout: .seconds(300))
            self.batch = nil
            self.nativeBatch = nil
            return result
        case "cmux.importHistory.finish":
            try requireGesture(context)
            batch = nil
            nativeBatch = nil
            finish(params["completed"]?.boolValue == true)
            return [:]
        default: throw PageError.unknownOp(op)
        }
    }

    #if DEBUG
    static func debugFixtureZip(_ path: String, home: URL) throws -> URL {
        let home = home.resolvingSymlinksInPath().standardizedFileURL.path
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(home + "/"), url.pathExtension.lowercased() == "zip",
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw PageError.invalidParams("the test export must be a regular zip inside this HOME")
        }
        return url
    }
    #endif

    private func admitZip(_ url: URL) -> JSONValue {
        let source = "zip:" + url.path
        admitted[source] = ""
        return ["source": .string(source), "name": .string(url.lastPathComponent)]
    }

    private func completeTransaction(_ arguments: [String], timeout: Duration) async throws -> JSONValue {
        try Task.checkCancellation()
        // task-owner: one already-started memory write/restore, bounded by the CLI timeout and
        // joined here. Closing the page cancels its router call, never the transaction midway
        // through its database write and import ledger. This call retains the paste files until
        // the transaction settles, then its defer restarts the Chief and releases the provider.
        let transaction = Task { @MainActor [run] in try await run(arguments, timeout) }
        return try await transaction.value
    }

    private func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: personOnlyMessage)
        }
        spentGesture = event
    }

    private nonisolated static func pasteFile(_ text: String) async throws -> (URL, URL) {
        // task-owner: one off-main file write; the provider removes its folder when the page closes
        try await Task.detached(priority: .utility) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-history-\(UUID().uuidString)")
            try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("memory.txt")
            guard FileManager.checked.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                try? FileManager.checked.removeItem(at: folder)
                throw CocoaError(.fileWriteUnknown)
            }
            return (folder, file)
        }.value
    }
}
