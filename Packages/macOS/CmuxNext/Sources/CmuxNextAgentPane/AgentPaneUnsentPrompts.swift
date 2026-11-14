public import CmuxNextSettings
import CmuxNextCompat
import CryptoKit
public import Foundation
import os

/// Every prompt the person sent from an agent chat that no agent has taken yet, kept on this Mac
/// by chat so a relaunch, a crash or an update never loses one (Leo, 2026-11-11: "when restarting
/// ALL MY ... UNSENT ... GOT DELETED").
///
/// The pane's web store does not survive a relaunch, and ``AgentPanePromptJournal`` keeps only the
/// frames in flight to this Mac's own acpmux, until acpmux answers: a prompt acpmux refused (a
/// remote chat's `remote.local_claude_session`, a dropped connection, no answer in time) lived only
/// in the page, as its Not sent row. This store keeps those rows' prompts, for chats on any machine:
///
/// - The page puts a prompt when it draws its row (`chat.unsentPrompt.put`) and takes it out only
///   when an agent has it (acpmux's acknowledgement or its echo), or the person removed it or took
///   it back into the composer (`chat.unsentPrompt.remove`). A refusal or an error never removes one.
/// - The page reads a chat's prompts when it shows the chat (`chat.unsentPrompts.get`), before its
///   connection is up, and draws each as a Not sent row with Retry, Edit and Remove.
///
/// One file per chat, so one damaged file never costs another chat its prompts. Writes are per
/// prompt (never "the whole list as the page sees it now"), so a page that has not read a chat yet
/// can never write an empty list over it. Each write is atomic (a temporary file renamed over the
/// old one) and keeps the file it replaces as `.bak`. A file that cannot be read or decoded is
/// moved aside (`.unreadable-<time>`), never written over: its prompts are read from the `.bak`,
/// and nothing is written for that chat until the move worked.
public nonisolated final class AgentPaneUnsentPrompts: Sendable {
    public static let directoryName = "agent-unsent-prompts"
    /// The app's store; nil keeps nothing (a test host, the gallery).
    /// `<Application Support>/<bundle id>/agent-unsent-prompts`, beside the prompt journal, which
    /// owns it (one store, so one queue keeps each chat's writes in order). Nil outside an app
    /// bundle (package tests, tools), so they never write the app's files.
    public static var shared: AgentPaneUnsentPrompts? { AgentPanePromptJournal.shared?.unsentPrompts }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.unsent-prompts")
    public let directory: URL
    let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.unsent-prompts", qos: .utility)

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory.appending(path: Self.directoryName, directoryHint: .isDirectory)
        self.now = now
    }

    /// The ops this store answers, on both hosts.
    public static func handles(method: String) -> Bool {
        method == "chat.unsentPrompt.put" || method == "chat.unsentPrompt.remove" || method == "chat.unsentPrompts.get"
    }

    /// One kept prompt: its id, the page's own record of it (text, chips, why it was not sent), and
    /// when it was put.
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var promptId: String
        var prompt: JSONValue
        var at: Date
    }

    private nonisolated struct Document: Codable {
        var version = 1
        var sessionId: String
        var prompts: [Entry]
    }

    /// The prompts kept for chat `sessionId`, oldest first.
    public func prompts(for sessionId: String) async -> [JSONValue] {
        await onQueue { self.read(sessionId).map(\.prompt) }
    }

    /// Keeps `prompt` (the page's record, an object with a string `promptId`) for `sessionId`,
    /// replacing an earlier record of the same prompt. False when it could not be written.
    @discardableResult
    public func put(_ prompt: JSONValue, for sessionId: String) async -> Bool {
        guard case .object(let body) = prompt, case .string(let promptId)? = body["promptId"], !promptId.isEmpty else { return false }
        return await onQueue {
            var entries = self.read(sessionId)
            let at = entries.first { $0.promptId == promptId }?.at ?? self.now()
            entries.removeAll { $0.promptId == promptId }
            entries.append(Entry(promptId: promptId, prompt: prompt, at: at))
            return self.write(entries, for: sessionId)
        }
    }

    /// Forgets prompt `promptId` of chat `sessionId`: an agent has it, or the person removed it or
    /// took it back into the composer.
    @discardableResult
    public func remove(_ promptId: String, for sessionId: String) async -> Bool {
        await onQueue {
            let entries = self.read(sessionId)
            guard entries.contains(where: { $0.promptId == promptId }) else { return true }
            return self.write(entries.filter { $0.promptId != promptId }, for: sessionId)
        }
    }

    /// Returns once every queued write so far is on disk (tests).
    public func settle() async { await onQueue {} }

    func file(for sessionId: String) -> URL {
        let digest = SHA256.hash(data: Data(sessionId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: String(digest.prefix(32)) + ".json")
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }

    // MARK: - Disk (on `queue` only)

    private nonisolated enum Read {
        case none
        case entries([Entry])
        case unreadable
    }

    private static func decode(_ url: URL, sessionId: String) -> Read {
        guard FileManager.checked.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(blockingContentsOf: url),
              let document = try? decoder.decode(Document.self, from: data), document.sessionId == sessionId else { return .unreadable }
        return .entries(document.prompts)
    }

    private func backup(of url: URL) -> URL { url.appendingPathExtension("bak") }

    /// The chat's prompts. A file that cannot be read is moved aside first (never written over) and
    /// its backup read instead.
    private func read(_ sessionId: String) -> [Entry] {
        let url = file(for: sessionId)
        switch Self.decode(url, sessionId: sessionId) {
        case .none:
            // No file: never written, or set aside as unreadable by an earlier read (an emptied
            // chat keeps its file, with no prompts). Its backup is then the newest readable copy.
            if case .entries(let entries) = Self.decode(backup(of: url), sessionId: sessionId) { return entries }
            return []
        case .entries(let entries): return entries
        case .unreadable:
            setAside(url)
            if case .entries(let entries) = Self.decode(backup(of: url), sessionId: sessionId) { return entries }
            return []
        }
    }

    /// Moves an unreadable file beside itself; true when nothing unreadable is left at `url`.
    @discardableResult
    private func setAside(_ url: URL) -> Bool {
        let files = FileManager.checked
        guard files.fileExists(atPath: url.path) else { return true }
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(now().timeIntervalSince1970 * 1000))")
            .appendingPathExtension("json")
        do {
            try files.moveItem(at: url, to: aside)
            Self.logger.error("unsent prompts file unreadable; set aside, read from its backup")
            return true
        } catch {
            Self.logger.error("unsent prompts file unreadable and not set aside; not written over: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func write(_ entries: [Entry], for sessionId: String) -> Bool {
        let url = file(for: sessionId)
        let files = FileManager.checked
        // An unreadable file still in place is never written over.
        if case .unreadable = Self.decode(url, sessionId: sessionId), !setAside(url) { return false }
        // No age limit: a prompt stays until an agent takes it, or Remove or Edit takes it out.
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            // The file this write replaces stays as the one backup.
            if files.fileExists(atPath: url.path) {
                let bak = backup(of: url)
                try? files.removeItem(at: bak)
                try files.copyItem(at: url, to: bak)
            }
            let data = try Self.encoder.encode(Document(sessionId: sessionId, prompts: entries))
            try data.blockingWrite(to: url, options: [.atomic])
            return true
        } catch {
            Self.logger.error("unsent prompts not written: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension AgentPaneUnsentPrompts {
    /// The reply to `chat.unsentPrompt.put {sessionId, prompt}`, `chat.unsentPrompt.remove
    /// {sessionId, promptId}` and `chat.unsentPrompts.get {sessionId}` (answers `{prompts}`), the
    /// same on the pane's own host and the shared page host. No store: nothing kept, nothing read.
    nonisolated public static func reply(to method: String, params: JSONValue,
                                         store: AgentPaneUnsentPrompts? = shared) async -> Result<JSONValue, PageReplyError> {
        guard handles(method: method) else { return .failure(.invalid("No such unsent prompt request")) }
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty else {
            return .failure(.invalid("Unsent prompts need a sessionId"))
        }
        guard let store else {
            return .success(method == "chat.unsentPrompts.get" ? .object(["prompts": .array([])]) : .null)
        }
        switch method {
        case "chat.unsentPrompts.get":
            return .success(.object(["prompts": .array(await store.prompts(for: session))]))
        case "chat.unsentPrompt.put":
            guard let prompt = body["prompt"] else { return .failure(.invalid("An unsent prompt needs its record")) }
            return await store.put(prompt, for: session) ? .success(.null) : .failure(.notKept)
        default:
            guard case .string(let promptId)? = body["promptId"], !promptId.isEmpty else {
                return .failure(.invalid("An unsent prompt needs its promptId"))
            }
            return await store.remove(promptId, for: session) ? .success(.null) : .failure(.notKept)
        }
    }

    nonisolated public enum PageReplyError: Error, Equatable, Sendable {
        case invalid(String)
        case notKept

        public var code: String {
            switch self {
            case .invalid: "native.invalid_request"
            case .notKept: "native.failed"
            }
        }

        public var message: String {
            switch self {
            case .invalid(let text): text
            case .notKept: "The unsent prompt could not be saved"
            }
        }
    }
}
