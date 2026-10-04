import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDaemon
import CryptoKit
import Foundation
import Synchronization
import Testing

/// RED tests for Home attachments on the local owner (`home-attachments-v1`,
/// plans/cmux-next/home-messaging.md 10.2). `DaemonHomeSource` talks to a
/// scripted daemon socket that implements the proposed wire
/// (`blob-upload-begin/-chunk/-commit`, ranged `get-blob`). Today every test
/// fails at run time: `upload` and `fetch` fall through to the `HomeSource`
/// defaults (`invalid("attachments unsupported")`), and `HomeCoreMapping`
/// turns an attachment part into a text part.
@Suite(.timeLimit(.minutes(1))) struct DaemonHomeSourceAttachmentTests {
    nonisolated static let chunkBytes = 1_048_576

    /// The scripted daemon's blob store and request log.
    nonisolated final class FakeBlobs: Sendable {
        nonisolated struct State {
            var requests: [[String: CmuxNextDaemon.JSONValue]] = []
            var stored: [String: (mime: String, data: Data)] = [:]
            var staging: [String: (sha: String, mime: String, count: Int, data: Data)] = [:]
        }
        let state = Mutex(State())

        var commands: [String] { state.withLock { $0.requests.compactMap { $0["cmd"]?.stringValue } } }

        func store(_ data: Data, mime: String) {
            state.withLock { $0.stored[DaemonHomeSourceAttachmentTests.sha256(data)] = (mime, data) }
        }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func reply(_ id: Int, _ data: [String: Any]) -> String {
        let body = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": data])
        return String(decoding: body ?? Data(), as: UTF8.self)
    }

    nonisolated static func refuse(_ id: Int, _ code: String) -> String {
        #"{"id":\#(id),"ok":false,"error":"\#(code)","error_code":"\#(code)"}"#
    }

    /// The proposed daemon wire, kept as small as the tests need.
    nonisolated static func daemon(_ blobs: FakeBlobs) -> @Sendable ([String: CmuxNextDaemon.JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            blobs.state.withLock { $0.requests.append(request) }
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = (DaemonCapabilities.shared.required + ["icon-assets-v1", "home-attachments-v1"])
                    .map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "blob-upload-begin":
                let sha = request["sha256"]?.stringValue ?? ""
                let mime = request["media_type"]?.stringValue ?? ""
                let count = request["byte_count"]?.doubleValue.map { Int($0) } ?? -1
                let exists = blobs.state.withLock { state -> Bool in
                    if state.stored[sha] != nil { return true }
                    state.staging["upl_\(sha.prefix(8))"] = (sha, mime, count, Data())
                    return false
                }
                return [reply(id, ["upload": "upl_\(sha.prefix(8))", "exists": exists, "received": 0,
                                   "chunk_bytes": chunkBytes])]
            case "blob-upload-chunk":
                let upload = request["upload"]?.stringValue ?? ""
                let offset = request["offset"]?.doubleValue.map { Int($0) } ?? -1
                let bytes = Data(base64Encoded: request["data"]?.stringValue ?? "") ?? Data()
                let received = blobs.state.withLock { state -> Int? in
                    guard var open = state.staging[upload], open.data.count == offset, bytes.count <= chunkBytes else {
                        return nil
                    }
                    open.data.append(bytes)
                    state.staging[upload] = open
                    return open.data.count
                }
                guard let received else { return [refuse(id, "upload_offset_mismatch")] }
                return [reply(id, ["received": received])]
            case "blob-upload-commit":
                let upload = request["upload"]?.stringValue ?? ""
                let committed = blobs.state.withLock { state -> (String, String, Int)? in
                    guard let open = state.staging.removeValue(forKey: upload), open.data.count == open.count,
                          sha256(open.data) == open.sha else { return nil }
                    state.stored[open.sha] = (open.mime, open.data)
                    return (open.sha, open.mime, open.count)
                }
                guard let committed else { return [refuse(id, "blob_hash_mismatch")] }
                let (sha, mime, size) = committed
                return [reply(id, ["ref": "blob:sha256-\(sha)", "media_type": mime, "size": size])]
            case "get-blob":
                let name = request["blob"]?.stringValue ?? ""
                let sha = String(name.dropFirst("blob:sha256-".count))
                let offset = request["offset"]?.doubleValue.map { Int($0) } ?? 0
                guard let blob = blobs.state.withLock({ $0.stored[sha] }) else { return [refuse(id, "not_found")] }
                let end = min(offset + chunkBytes, blob.data.count)
                let slice = blob.data.subdata(in: min(offset, end)..<end)
                return [reply(id, ["ref": name, "media_type": blob.mime, "size": blob.data.count, "offset": offset,
                                   "data": slice.base64EncodedString()])]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    /// A source connected to the scripted daemon.
    nonisolated static func connectedSource(_ blobs: FakeBlobs) async throws -> (DaemonHomeSource, DaemonConnection, ScriptedDaemonSocket) {
        let server = try ScriptedDaemonSocket(handler: daemon(blobs))
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        _ = try await connection.start()
        let source = DaemonHomeSource(me: Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Me"))
        source.connectionChanged(connection)
        return (source, connection, server)
    }

    nonisolated static func file(bytes count: Int, seed: UInt8) throws -> (URL, Data) {
        var data = Data("PK\u{3}\u{4}".utf8)
        data.append(Data(repeating: seed, count: count - data.count))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("l16-attach-\(UUID().uuidString).zip")
        try data.write(to: url)
        return (url, data)
    }

    nonisolated static let conversation = ConversationID("conv_01JABCDEFGHJKMNPQRSTVWXYZ0")

    /// RED today: `upload` throws `invalid("attachments unsupported")`.
    @Test func uploadSendsContiguousChunksThenCommitsAndReturnsTheRef() async throws {
        let blobs = FakeBlobs()
        let (source, connection, server) = try await Self.connectedSource(blobs)
        defer { server.stop() }
        let (url, data) = try Self.file(bytes: 2 * Self.chunkBytes + 4321, seed: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let ref = AttachmentRef(hash: Self.sha256(data), name: "notes.zip", mimeType: "application/zip", byteCount: data.count)

        let stored = try await source.upload(AttachmentUpload(conversation: Self.conversation, fileURL: url, ref: ref))

        #expect(stored == ref)
        let blobCommands = blobs.commands.filter { $0.hasPrefix("blob-") }
        #expect(blobCommands == ["blob-upload-begin", "blob-upload-chunk", "blob-upload-chunk", "blob-upload-chunk",
                                 "blob-upload-commit"])
        let begin = try #require(blobs.state.withLock { $0.requests.first { $0["cmd"]?.stringValue == "blob-upload-begin" } })
        #expect(begin["purpose"]?.stringValue == "attachment")
        #expect(begin["media_type"]?.stringValue == "application/zip")
        #expect(begin["sha256"]?.stringValue == ref.hash)
        #expect(begin["byte_count"]?.doubleValue == Double(data.count))
        #expect(blobs.state.withLock { $0.stored[ref.hash]?.data } == data)
        await connection.close()
    }

    /// RED today: `upload` throws. A video's poster goes up before the video,
    /// so the owner can check the part's poster against a stored blob.
    @Test func uploadSendsThePosterBeforeTheVideo() async throws {
        let blobs = FakeBlobs()
        let (source, connection, server) = try await Self.connectedSource(blobs)
        defer { server.stop() }
        let (videoURL, video) = try Self.file(bytes: 300_000, seed: 2)
        var poster = Data([0xFF, 0xD8, 0xFF, 0xE0])
        poster.append(Data(repeating: 3, count: 2_000))
        let posterURL = FileManager.default.temporaryDirectory.appendingPathComponent("l16-poster-\(UUID().uuidString).jpg")
        try poster.write(to: posterURL)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: posterURL)
        }
        let ref = AttachmentRef(hash: Self.sha256(video), name: "clip.mov", mimeType: "video/quicktime", byteCount: video.count,
                                durationMs: 1_000,
                                poster: AttachmentPoster(hash: Self.sha256(poster), mimeType: "image/jpeg", byteCount: poster.count))

        _ = try await source.upload(AttachmentUpload(conversation: Self.conversation, fileURL: videoURL, ref: ref, posterURL: posterURL))

        let begins = blobs.state.withLock { $0.requests.filter { $0["cmd"]?.stringValue == "blob-upload-begin" } }
        #expect(begins.map { $0["sha256"]?.stringValue } == [Self.sha256(poster), Self.sha256(video)])
        await connection.close()
    }

    /// RED today: `upload` throws. Bytes the daemon already holds move no chunk.
    @Test func uploadOfStoredBytesSendsNoChunk() async throws {
        let blobs = FakeBlobs()
        let (source, connection, server) = try await Self.connectedSource(blobs)
        defer { server.stop() }
        let (url, data) = try Self.file(bytes: 5_000, seed: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        blobs.store(data, mime: "application/zip")
        let ref = AttachmentRef(hash: Self.sha256(data), name: "a.zip", mimeType: "application/zip", byteCount: data.count)

        _ = try await source.upload(AttachmentUpload(conversation: Self.conversation, fileURL: url, ref: ref))

        #expect(blobs.commands.filter { $0.hasPrefix("blob-") } == ["blob-upload-begin"])
        await connection.close()
    }

    /// RED today: `fetch` throws `invalid("attachments unsupported")`.
    @Test func fetchOriginalReadsRangesIntoOneVerifiedLocalFile() async throws {
        let blobs = FakeBlobs()
        let (source, connection, server) = try await Self.connectedSource(blobs)
        defer { server.stop() }
        var data = Data("PK\u{3}\u{4}".utf8)
        data.append(Data((0..<(Self.chunkBytes + 99)).map { UInt8(truncatingIfNeeded: $0) }))
        blobs.store(data, mime: "application/zip")
        let ref = AttachmentRef(hash: Self.sha256(data), name: "a.zip", mimeType: "application/zip", byteCount: data.count)

        let url = try await source.fetch(ref, at: AttachmentLocation(conversation: Self.conversation), variant: .original)

        #expect(try Data(contentsOf: url) == data)
        #expect(blobs.commands.filter { $0 == "get-blob" }.count == 2, "1 MiB per reply")
        await connection.close()
    }

    /// RED today: the error is `invalid("attachments unsupported")`, not
    /// `invalid("no_poster")`. A part without a poster never fetches the
    /// video in its place.
    @Test func fetchPosterOfAPartWithoutAPosterThrowsNoPoster() async throws {
        let blobs = FakeBlobs()
        let (source, connection, server) = try await Self.connectedSource(blobs)
        defer { server.stop() }
        let ref = AttachmentRef(hash: String(repeating: "a", count: 64), name: "clip.mov", mimeType: "video/quicktime",
                                byteCount: 10)

        await #expect(throws: HomeRejection.invalid("no_poster")) {
            _ = try await source.fetch(ref, at: AttachmentLocation(conversation: Self.conversation), variant: .poster)
        }
        #expect(blobs.commands.filter { $0 == "get-blob" }.isEmpty)
        await connection.close()
    }

    /// RED today: `HomeCoreMapping.parts` sends an attachment as a text part.
    @Test func mappingSendsAnAttachmentInTheOwnersPartShape() throws {
        let ref = AttachmentRef(hash: String(repeating: "b", count: 64), name: "p.jpg", mimeType: "image/jpeg", byteCount: 900,
                                width: 40, height: 30,
                                preview: AttachmentDerivedImage(hash: String(repeating: "c", count: 64), mimeType: "image/jpeg",
                                                                byteCount: 100))
        let encoded = try JSONEncoder().encode(HomeCoreMapping.parts([.attachment(ref)]))
        let wire = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(wire.first?["type"] as? String == "attachment")
        #expect(wire.first?["hash"] as? String == ref.hash)
        #expect(wire.first?["mime_type"] as? String == "image/jpeg")
        #expect(wire.first?["byte_count"] as? Int == 900)
        #expect((wire.first?["preview"] as? [String: Any])?["hash"] as? String == ref.preview?.hash)
    }

    /// RED today: an owner attachment part decodes as `.unknown` and maps to
    /// something other than `.attachment`.
    @Test func mappingReadsAnOwnerAttachmentPart() throws {
        let hash = String(repeating: "d", count: 64)
        let json = #"{"type":"attachment","hash":"\#(hash)","name":"a.pdf","mime_type":"application/pdf","byte_count":10}"#
        let part = try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
        #expect(HomeCoreMapping.part(part)
            == .attachment(AttachmentRef(hash: hash, name: "a.pdf", mimeType: "application/pdf", byteCount: 10)))
    }
}
