import CmuxHomeCore
import CmuxNextDaemon
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextApp

/// Home attachments on the local conversation owner (`local-attachments-v1`):
/// a pasted image in a local Chief chat uploads to the daemon by SHA-256 and
/// comes back for every reader. Before this, `DaemonHomeSource` had no blob
/// store and every image send failed with "attachments unsupported".
@Suite(.timeLimit(.minutes(1))) struct DaemonHomeSourceAttachmentTests {
    /// An owner that keeps what `conversation-attachment-upload` sends and
    /// answers `conversation-attachment-read` from it, like cmux-tui.
    nonisolated final class Owner: Sendable {
        struct Upload: Sendable {
            var sha256: String
            var mimeType: String
            var preview: (sha256: String, mime: String)?
            var bytes: [String: Data] = [:]
        }

        struct Record: Sendable {
            var mimeType: String
            var bytes: Data
            var preview: (sha256: String, mime: String, bytes: Data)?
        }

        let uploads = Mutex<[String: Upload]>([:])
        let records = Mutex<[String: Record]>([:])
        let chunks = Mutex(0)
        let refuseWith = Mutex<String?>(nil)
        let socket: ScriptedDaemonSocket

        init() throws {
            let uploads = uploads, records = records, chunks = chunks, refuseWith = refuseWith
            socket = try ScriptedDaemonSocket { request in
                let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
                func ok(_ data: String) -> [String] { [#"{"id":\#(id),"ok":true,"data":\#(data)}"#] }
                func refused(_ reason: String) -> [String] {
                    [#"{"id":\#(id),"ok":false,"error":"\#(reason)","error_code":"attachment_rejected"}"#]
                }
                switch request["cmd"]?.stringValue {
                case "identify":
                    let caps = (DaemonCapabilities.shared.required + ["local-conversations-v1", "local-attachments-v1"])
                        .map { "\"\($0)\"" }.joined(separator: ",")
                    return ok(#"{"app":"cmux-tui","version":"0.1.0","build_commit":"abc","protocol":12,"capabilities":[\#(caps)],"session":"t","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}"#)
                case "conversation-attachment-upload":
                    switch request["op"]?.stringValue {
                    case "begin":
                        if let reason = refuseWith.withLock({ $0 }) { return refused(reason) }
                        let sha = request["sha256"]?.stringValue ?? ""
                        var upload = Upload(sha256: sha, mimeType: request["mime_type"]?.stringValue ?? "")
                        var needs = [#""original""#]
                        if case .object(let preview)? = request["preview"] {
                            upload.preview = (preview["sha256"]?.stringValue ?? "", preview["mime_type"]?.stringValue ?? "")
                            needs.append(#""preview""#)
                        }
                        let uploadID = "u\(sha.prefix(8))"
                        uploads.withLock { $0[uploadID] = upload }
                        return ok(#"{"upload":"\#(uploadID)","needs":[\#(needs.joined(separator: ","))],"stored":null}"#)
                    case "chunk":
                        let uploadID = request["upload"]?.stringValue ?? ""
                        let piece = request["piece"]?.stringValue ?? ""
                        let data = Data(base64Encoded: request["data"]?.stringValue ?? "") ?? Data()
                        chunks.withLock { $0 += 1 }
                        let received = uploads.withLock { uploads -> Int in
                            uploads[uploadID]?.bytes[piece, default: Data()].append(data)
                            return uploads[uploadID]?.bytes[piece]?.count ?? 0
                        }
                        return ok(#"{"received":\#(received)}"#)
                    case "commit":
                        let uploadID = request["upload"]?.stringValue ?? ""
                        guard let upload = uploads.withLock({ $0.removeValue(forKey: uploadID) }),
                              let original = upload.bytes["original"],
                              Self.hex(original) == upload.sha256 else { return refused("hash_mismatch") }
                        var preview: (String, String, Data)?
                        var previewJSON = ""
                        if let declared = upload.preview, let bytes = upload.bytes["preview"] {
                            preview = (declared.sha256, declared.mime, bytes)
                            previewJSON = #","preview":{"hash":"\#(declared.sha256)","mime_type":"\#(declared.mime)","byte_count":\#(bytes.count)}"#
                        }
                        records.withLock { $0[upload.sha256] = Record(mimeType: upload.mimeType, bytes: original, preview: preview) }
                        return ok(#"{"stored":{"hash":"\#(upload.sha256)","mime_type":"\#(upload.mimeType)","byte_count":\#(original.count)\#(previewJSON)}}"#)
                    default:
                        return ok("{}")
                    }
                case "conversation-attachment-read":
                    let hash = request["hash"]?.stringValue ?? ""
                    let variant = request["variant"]?.stringValue ?? "original"
                    let offset = request["offset"]?.doubleValue.map { Int($0) } ?? 0
                    let length = request["length"]?.doubleValue.map { Int($0) } ?? 4 << 20
                    guard let record = records.withLock({ $0[hash] }) else { return refused("unknown_attachment") }
                    let piece: (hash: String, mime: String, bytes: Data)
                    switch variant {
                    case "preview":
                        guard let preview = record.preview else { return refused("no_preview") }
                        piece = preview
                    case "poster":
                        return refused("no_poster")
                    default:
                        piece = (hash, record.mimeType, record.bytes)
                    }
                    let end = min(piece.bytes.count, offset + length)
                    let slice = piece.bytes.subdata(in: min(offset, end)..<end)
                    return ok(#"{"hash":"\#(piece.hash)","mime_type":"\#(piece.mime)","byte_count":\#(piece.bytes.count),"offset":\#(offset),"data":"\#(slice.base64EncodedString())","eof":\#(end >= piece.bytes.count)}"#)
                default:
                    return ok("{}")
                }
            }
        }

        static func hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A real PNG of `width` x `height` pixels, and its SHA-256.
    static func png(width: Int, height: Int, in directory: URL, name: String) throws -> (url: URL, data: Data) {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let url = directory.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return (url, data as Data)
    }

    func connectedSource(_ owner: Owner) async throws -> (DaemonHomeSource, DaemonConnection) {
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: owner.socket.path))
        try await connection.start()
        let me = Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Me")
        let source = DaemonHomeSource(me: me)
        source.connectionChanged(connection)
        return (source, connection)
    }

    @Test func aPastedImageUploadsToTheLocalOwnerAndComesBackForEveryVariant() async throws {
        let owner = try Owner()
        defer { owner.socket.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dhs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try Self.png(width: 300, height: 200, in: directory, name: "shot.png")
        let preview = Data("preview-jpeg".utf8)
        let previewURL = directory.appendingPathComponent("preview.jpg")
        try preview.write(to: previewURL)
        let ref = AttachmentRef(hash: Owner.hex(image.data), name: "shot.png", mimeType: "image/png", byteCount: image.data.count,
                                width: 300, height: 200,
                                preview: AttachmentDerivedImage(hash: Owner.hex(preview), mimeType: "image/jpeg", byteCount: preview.count))
        let (source, connection) = try await connectedSource(owner)
        defer { Task { await connection.close() } }
        let progress = Mutex<[Double]>([])
        let stored = try await source.upload(AttachmentUpload(conversation: ConversationID("conv_A"), fileURL: image.url, ref: ref,
                                                              previewURL: previewURL) { fraction in
            progress.withLock { $0.append(fraction) }
        })
        #expect(stored.hash == ref.hash)
        #expect(stored.mimeType == "image/png")
        #expect(stored.byteCount == image.data.count)
        #expect(stored.preview == ref.preview)
        #expect(owner.records.withLock { $0[ref.hash]?.bytes } == image.data)
        #expect(progress.withLock { $0.last } == 1)

        let location = AttachmentLocation(conversation: ConversationID("conv_A"), message: MessageID("msg_1"), partIndex: 0)
        let original = try await source.fetch(ref, at: location, variant: .original)
        #expect(try Data(contentsOf: original) == image.data)
        #expect(try await source.fetch(ref, at: location, variant: .original) == original, "the same file for the same variant")
        #expect(try Data(contentsOf: try await source.fetch(ref, at: location, variant: .preview)) == preview)
        let thumbnail = try await source.fetch(ref, at: location, variant: .thumbnail(maxPixel: 64))
        let thumbSource = try #require(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
        let thumb = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
        #expect(max(thumb.width, thumb.height) <= 64)
        await #expect(throws: HomeRejection.invalid("no_poster")) {
            _ = try await source.fetch(ref, at: location, variant: .poster)
        }
    }

    @Test func aRefusedTypeIsAFinalRejectionWithTheOwnersReason() async throws {
        let owner = try Owner()
        defer { owner.socket.stop() }
        owner.refuseWith.withLock { $0 = "type_refused" }
        let (source, connection) = try await connectedSource(owner)
        defer { Task { await connection.close() } }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dhs-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = AttachmentRef(hash: Owner.hex(Data("x".utf8)), name: "x.png", mimeType: "image/png", byteCount: 1)
        await #expect(throws: HomeRejection.invalid("type_refused")) {
            _ = try await source.upload(AttachmentUpload(conversation: ConversationID("conv_A"), fileURL: file, ref: ref))
        }
    }
}
