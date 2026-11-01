import Foundation

/// Replies the content extension hands the app (and replies the app keeps
/// for a retry): one JSON file per reply. Safe across the two processes
/// without `NSFileCoordinator` (whose daemon stalled reads for seconds in the
/// simulator): a writer writes atomically (temporary file, then rename), so a
/// reader never sees half a file, and `take` claims a file by renaming it to a
/// name of its own first, so two processes never both take one reply. The app
/// drains it on launch and on every return to the foreground; nothing polls.
public struct PushOutbox: Sendable {
    /// A reply older than this is dropped unsent: its question has likely moved on.
    public static let maxAge: TimeInterval = 15 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init?(group: PushAppGroup?) {
        guard let group else { return nil }
        self.init(directory: group.directory.appendingPathComponent("PushOutbox", isDirectory: true))
    }

    /// Where a reply's attachments go (file names in `PushReply.Action.text`).
    public var attachments: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// What the long look's "+" picked for one notification, waiting for its
    /// Reply (the system text field), which the app delegate receives.
    var staged: URL { directory.appendingPathComponent("staged", isDirectory: true) }

    func stagedFile(_ requestID: String) -> URL {
        let key = Data(requestID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        return staged.appendingPathComponent(String(key.prefix(200)) + ".json")
    }

    /// Stages `names` (files in `attachments`) for the notification `requestID`; none clears it.
    public func stage(_ names: [String], for requestID: String) throws {
        let url = stagedFile(requestID)
        guard !names.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try JSONEncoder().encode(names).write(to: url, options: Data.WritingOptions.pushFile)
    }

    /// Takes what was staged for `requestID`: plain file names that still exist,
    /// while fresh (`maxAge`); nothing when another process took it first.
    public func takeStaged(for requestID: String, now: Date = Date()) -> [String] {
        let url = stagedFile(requestID)
        let claimed = staged.appendingPathComponent(UUID().uuidString + ".taken")
        guard (try? FileManager.default.moveItem(at: url, to: claimed)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let date = (try? claimed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard now.timeIntervalSince(date) < Self.maxAge,
              let names = (try? Data(contentsOf: claimed)).flatMap({ try? JSONDecoder().decode([String].self, from: $0) }) else { return [] }
        return names.filter { name in
            (name as NSString).lastPathComponent == name && !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: attachments.appendingPathComponent(name).path)
        }
    }

    public struct Refused: Error, Equatable, Sendable {}

    /// Queues `reply` for the app. Text into a terminal is refused: the outbox
    /// is written before the phone unlocks, and only the unlock-gated Reply
    /// button may type into a terminal (PR B security review H2).
    public func put(_ reply: PushReply) throws {
        if case .text = reply.action, reply.kind == .terminal { throw Refused() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(reply).write(to: file(reply.id), options: Data.WritingOptions.pushFile)
    }

    /// Removes and returns one reply; nil when it is gone or another process took it.
    @discardableResult
    public func take(_ id: UUID) -> PushReply? {
        let claimed = directory.appendingPathComponent("\(id.uuidString).\(UUID().uuidString).taken")
        guard (try? FileManager.default.moveItem(at: file(id), to: claimed)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: claimed) }
        return Self.read(claimed)
    }

    /// Every waiting reply, oldest first; expired and unreadable ones are deleted.
    public func all(now: Date = Date()) -> [PushReply] {
        pruneAttachments(now: now)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [PushReply] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let reply = Self.read(url), now.timeIntervalSince(reply.createdAt) < Self.maxAge else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            out.append(reply)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes and returns every waiting reply, oldest first.
    public func takeAll(now: Date = Date()) -> [PushReply] {
        all(now: now).compactMap { take($0.id) }
    }

    /// Deletes the named attachments (after their reply was sent). A name that
    /// is not a plain file name is ignored.
    public func removeAttachments(_ names: [String]) {
        for name in names where (name as NSString).lastPathComponent == name && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: attachments.appendingPathComponent(name))
        }
    }

    /// Brings a picked file into `attachments` as `name` (moved when `move`, else
    /// copied) and dates it now: a copy or a move keeps the original's date, and
    /// `pruneAttachments` ages files by it, so a document last edited days ago
    /// would be pruned before its reply is sent.
    public func adopt(_ source: URL, as name: String, move: Bool, now: Date = Date()) throws {
        guard (name as NSString).lastPathComponent == name, !name.hasPrefix(".") else { throw Refused() }
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let target = attachments.appendingPathComponent(name)
        if move {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try FileManager.default.copyItem(at: source, to: target)
        }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
    }

    /// Deletes attachments, and stages of notifications never replied to, older
    /// than `maxAge` (their reply expired unsent).
    public func pruneAttachments(now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        for folder in [attachments, staged] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for url in files {
                let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(date) >= Self.maxAge { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Sign-out: every waiting reply and attachment.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func read(_ url: URL) -> PushReply? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PushReply.self, from: $0) }
    }
}

/// Replies a "Couldn't reach" notification retries, in the app's own
/// container (never the App Group): the notification carries only the id
/// (`PushReply.retryUserInfo`), and a retry is taken only for a notification
/// the app posted itself (PR #24156 review H1).
public struct PushRetryStore: Sendable {
    let outbox: PushOutbox

    public init(directory: URL) {
        outbox = PushOutbox(directory: directory)
    }

    /// `Application Support/PushRetries` of the running app.
    public static var app: PushRetryStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return PushRetryStore(directory: base.appendingPathComponent("PushRetries", isDirectory: true))
    }

    public func put(_ reply: PushReply) throws {
        try outbox.put(reply)
    }

    /// The reply a notification response retries: only for a local
    /// notification (`fromPush` false), taken once, and only while fresh.
    public func resolve(userInfo: [AnyHashable: Any], fromPush: Bool, now: Date = Date()) -> PushReply? {
        guard !fromPush, let text = userInfo[PushReply.retryIDKey] as? String, let id = UUID(uuidString: text),
              let reply = outbox.take(id), now.timeIntervalSince(reply.createdAt) < PushOutbox.maxAge else { return nil }
        return reply
    }

    /// Sign-out.
    public func removeAll() {
        outbox.removeAll()
    }
}

/// A chat's recent messages, saved by the app for the content extension's
/// preview (it has no link). Bounded: 8 messages of 280 characters per
/// session, 64 sessions.
public struct PushSnapshot: Codable, Sendable, Equatable {
    public struct Message: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable { case user, agent, system }
        public var role: Role
        public var text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// The `session` key of a Mac's Chief conversation (its pushes carry the
    /// turn's session, not the conversation).
    public static let chiefSession = "chief"

    public var mac: String
    public var session: String
    public var title: String?
    /// Chief's avatar text (an emoji or initials), as Home and the chat draw it.
    public var avatar: String?
    public var messages: [Message]
    public var updatedAt: Date

    public init(mac: String, session: String, title: String? = nil, avatar: String? = nil, messages: [Message], updatedAt: Date = Date()) {
        self.mac = mac
        self.session = session
        self.title = title
        self.avatar = avatar
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

public struct PushSnapshotStore: Sendable {
    public static let maxMessages = 8
    public static let maxCharacters = 280
    public static let maxSessions = 64

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init?(group: PushAppGroup?) {
        guard let group else { return nil }
        self.init(directory: group.directory.appendingPathComponent("PushSnapshots", isDirectory: true))
    }

    func file(mac: String, session: String) -> URL {
        let key = Data("\(mac)\u{0}\(session)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(String(key.prefix(240)) + ".json")
    }

    /// Saves the last messages (bounded); skips the write when nothing changed.
    public func save(_ snapshot: PushSnapshot) {
        var snapshot = snapshot
        snapshot.messages = snapshot.messages.suffix(Self.maxMessages).map {
            PushSnapshot.Message(role: $0.role, text: String($0.text.prefix(Self.maxCharacters)))
        }
        if let old = load(mac: snapshot.mac, session: snapshot.session), old.messages == snapshot.messages, old.title == snapshot.title,
           old.avatar == snapshot.avatar { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: file(mac: snapshot.mac, session: snapshot.session),
                                                     options: Data.WritingOptions.pushFile)
        } catch {
            return
        }
        prune()
    }

    public func load(mac: String, session: String) -> PushSnapshot? {
        (try? Data(contentsOf: file(mac: mac, session: session))).flatMap { try? JSONDecoder().decode(PushSnapshot.self, from: $0) }
    }

    /// Sign-out and account deletion.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > Self.maxSessions else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxSessions) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension Data.WritingOptions {
    /// Atomic, and readable by an extension once the phone was unlocked after boot.
    static var pushFile: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}
