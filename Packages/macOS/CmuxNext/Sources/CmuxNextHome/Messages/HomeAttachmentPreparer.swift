public import CmuxHomeCore
public import CmuxNextSettings
import CmuxNextCompat
public import Foundation

/// The Messages page's photos and videos go through the host's own preparation before they upload
/// (`cmux.home.messages.attachments.prepare.*`), as the native composer's did
/// (``HomeStore/prepareAttachment(fileURL:keepLocation:)``): location metadata (a photo's GPS, a
/// video's ISO 6709 location) is removed unless Settings > Home keeps it
/// (`home.attachments.keepLocation`, off by default), and a type the owner refuses is converted.
///
/// The bytes move in chunks both ways (any size, about 1 MB a frame, as the upload's own):
/// - `begin {name, mimeType, byteCount}` -> `{keep: true}` (the setting keeps location: upload
///   the file as it is) or `{id}`;
/// - `chunk {id, offset, data}` (base64, in order);
/// - `finish {id}` -> `{changed: false}` (nothing to remove: upload the original) or
///   `{changed: true, name, mimeType, byteCount}`;
/// - `read {id, offset, length}` -> `{data}` (the prepared bytes);
/// - `end {id}`: the session's temporary file goes (also when the page gives up).
///
/// Cost: one temporary file per file being prepared (at most ``maxSessions``; the oldest goes past
/// that), written and read off the main actor.
@MainActor
public final class HomeAttachmentPreparer {
    /// More than a drop of files at once (each uploads at once, attachmentDrafts.ts).
    public static let maxSessions = 64
    public static let maxReadBytes = 3 * 1024 * 1024

    private struct Session {
        let input: URL
        let name: String
        let mimeType: String
        let byteCount: Int
        var written = 0
        var prepared: URL?
    }

    private let store: HomeStore
    private let keepLocation: @MainActor () -> Bool
    private let directory: URL
    private var sessions: [String: Session] = [:]
    private var order: [String] = []

    public init(store: HomeStore, keepLocation: @escaping @MainActor () -> Bool,
                directory: URL? = nil) {
        self.store = store
        self.keepLocation = keepLocation
        self.directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "cmux-home-prepare", directoryHint: .isDirectory)
    }

    public enum Failure: Error, Equatable {
        case invalid(String)
        case unknownSession
    }

    /// One op (the name after `attachments.prepare.`).
    public func call(_ op: String, _ fields: [String: JSONValue]) async throws -> JSONValue {
        switch op {
        case "begin":
            guard let name = fields["name"]?.stringValue, let mimeType = fields["mimeType"]?.stringValue,
                  let count = fields["byteCount"]?.doubleValue, count >= 0 else { throw Failure.invalid("begin needs name, mimeType and byteCount") }
            if keepLocation() { return .object(["keep": .bool(true)]) }
            let id = UUID().uuidString
            let input = directory.appending(path: id + "-in", directoryHint: .notDirectory)
            try await Self.create(input)
            sessions[id] = Session(input: input, name: name, mimeType: mimeType, byteCount: Int(count))
            order.append(id)
            while order.count > Self.maxSessions { end(order.removeFirst()) }
            return .object(["id": .string(id)])
        case "chunk":
            let (id, session) = try self.session(fields)
            guard let offset = fields["offset"]?.doubleValue, Int(offset) == session.written,
                  let data = fields["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  session.written + data.count <= session.byteCount else { throw Failure.invalid("chunk out of order or past byteCount") }
            try await Self.append(data, to: session.input)
            sessions[id]?.written += data.count
            return .null
        case "finish":
            let (id, session) = try self.session(fields)
            guard session.written == session.byteCount else { throw Failure.invalid("finish before every byte came") }
            let named = directory.appending(path: id, directoryHint: .isDirectory).appending(path: Self.safeName(session.name))
            try await Self.move(session.input, to: named)
            sessions[id] = Session(input: named, name: session.name, mimeType: session.mimeType, byteCount: session.byteCount,
                                   written: session.written)
            let prepared = try await store.prepareAttachment(fileURL: named, keepLocation: false)
            let same = await Self.same(named, prepared.fileURL)
            let changed = prepared.ref.mimeType != session.mimeType || prepared.ref.name != session.name || !same
            guard changed else { return .object(["changed": .bool(false)]) }
            sessions[id]?.prepared = prepared.fileURL
            return .object(["changed": .bool(true), "name": .string(prepared.ref.name), "mimeType": .string(prepared.ref.mimeType),
                            "byteCount": .number(Double(prepared.ref.byteCount))])
        case "read":
            let (_, session) = try self.session(fields)
            guard let file = session.prepared, let offset = fields["offset"]?.doubleValue, let length = fields["length"]?.doubleValue,
                  offset >= 0, length > 0, Int(length) <= Self.maxReadBytes else { throw Failure.invalid("read needs a finished, changed file") }
            let data = try await Self.read(file, offset: UInt64(offset), length: Int(length))
            return .object(["data": .string(data.base64EncodedString())])
        case "end":
            guard let id = fields["id"]?.stringValue else { throw Failure.invalid("end needs id") }
            end(id)
            return .null
        default:
            throw Failure.invalid("unknown prepare op \(op)")
        }
    }

    /// Every session ends (the page went away).
    public func endAll() {
        for id in order { end(id) }
    }

    private func session(_ fields: [String: JSONValue]) throws -> (String, Session) {
        guard let id = fields["id"]?.stringValue, let session = sessions[id] else { throw Failure.unknownSession }
        return (id, session)
    }

    private func end(_ id: String) {
        order.removeAll { $0 == id }
        guard sessions.removeValue(forKey: id) != nil else { return }
        let files = [directory.appending(path: id + "-in"), directory.appending(path: id, directoryHint: .isDirectory)]
        // task-owner: one cleanup of this session's temporary files; ends with it
        Task { await Self.remove(files) }
    }

    /// The file's name as one path component.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "attachment" : String(cleaned.prefix(200))
    }

    @concurrent nonisolated static func create(_ url: URL) async throws {
        try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.checked.createFile(atPath: url.path, contents: nil) else { throw Failure.invalid("no temporary file") }
    }

    @concurrent nonisolated static func append(_ data: Data, to url: URL) async throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.blockingWrite(contentsOf: data)
    }

    @concurrent nonisolated static func move(_ from: URL, to: URL) async throws {
        try FileManager.checked.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.checked.moveItem(at: from, to: to)
    }

    @concurrent nonisolated static func same(_ a: URL, _ b: URL) async -> Bool {
        FileManager.checked.contentsEqual(atPath: a.path, andPath: b.path)
    }

    @concurrent nonisolated static func read(_ url: URL, offset: UInt64, length: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.blockingRead(upToCount: length) ?? Data()
    }

    @concurrent nonisolated static func remove(_ urls: [URL]) async {
        for url in urls { try? FileManager.checked.removeItem(at: url) }
    }
}
