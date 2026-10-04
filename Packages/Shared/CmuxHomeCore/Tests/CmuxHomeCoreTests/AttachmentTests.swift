import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxHomeCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-attach-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A `width` x `height` JPEG whose EXIF orientation is `orientation`.
private func makeJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A one-second H.264 movie, `width` x `height` encoded, rotated 90 degrees
/// by its track transform (display size is `height` x `width`).
private func makeMovie(at url: URL, width: Int, height: Int, frames: Int = 10, fps: Int32 = 10) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting(), "AVAssetWriter could not start: \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { await Task.yield() }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, Int32(frame * 20 % 255), CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
    await writer.finishWriting()
    #expect(writer.status == .completed, "AVAssetWriter failed: \(String(describing: writer.error))")
}

@Suite struct AttachmentPreparationTests {
    @MainActor @Test func hashIsSHA256OfTheBytesAndTheBlobIsCached() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let bytes = Data("hello attachments".utf8)
        let fromData = try await store.prepareAttachment(data: bytes, typeIdentifier: UTType.plainText.identifier)
        #expect(fromData.ref.hash == sha256Hex(bytes))
        #expect(fromData.ref.byteCount == bytes.count)
        #expect(fromData.ref.mimeType == "text/plain")
        #expect(fromData.fileURL.deletingLastPathComponent().lastPathComponent == fromData.ref.hash)
        #expect(fromData.fileURL.path.hasPrefix(root.path))
        #expect(try Data(contentsOf: fromData.fileURL) == bytes)

        // A file larger than one hashing chunk takes the streamed path.
        var large = Data(count: AttachmentMedia.chunkSize * 2 + 123)
        for index in stride(from: 0, to: large.count, by: 997) { large[index] = UInt8(index % 251) }
        let file = root.appendingPathComponent("large.txt")
        try large.write(to: file)
        let fromFile = try await store.prepareAttachment(fileURL: file)
        #expect(fromFile.ref.hash == sha256Hex(large))
        #expect(fromFile.ref.byteCount == large.count)
        #expect(fromFile.ref.name == "large.txt")
        #expect(try Data(contentsOf: fromFile.fileURL) == large)
    }

    @MainActor @Test func imageSizeIsTheDisplaySizeAfterEXIFOrientation() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let file = root.appendingPathComponent("photo.jpg")
        try makeJPEG(width: 40, height: 20, orientation: 6).write(to: file)
        let prepared = try await store.prepareAttachment(fileURL: file)
        #expect(prepared.ref.mimeType == "image/jpeg")
        #expect(prepared.ref.width == 20)
        #expect(prepared.ref.height == 40)
        #expect(prepared.ref.durationMs == nil)
        #expect(prepared.posterURL == nil)

        let viaData = try await store.prepareAttachment(data: try Data(contentsOf: file), typeIdentifier: UTType.jpeg.identifier)
        #expect(viaData.ref.hash == prepared.ref.hash)
        #expect(viaData.ref.width == 20 && viaData.ref.height == 40)
    }

    @MainActor @Test func videoGetsDurationDisplaySizeAndPoster() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 128, height: 64)
        let prepared = try await store.prepareAttachment(fileURL: movie)
        #expect(prepared.ref.mimeType == "video/quicktime")
        #expect(prepared.ref.width == 64)
        #expect(prepared.ref.height == 128)
        let duration = try #require(prepared.ref.durationMs)
        #expect(abs(duration - 1000) <= 100)
        let poster = try #require(prepared.posterURL)
        let posterHash = try #require(prepared.ref.posterHash)
        #expect(sha256Hex(try Data(contentsOf: poster)) == posterHash)
        let posterSource = try #require(CGImageSourceCreateWithURL(poster as CFURL, nil))
        let posterImage = try #require(CGImageSourceCreateImageAtIndex(posterSource, 0, nil))
        #expect(posterImage.height > posterImage.width) // the transform is applied to the poster too
    }

    @MainActor @Test func policyRefusesTypesAndSizesBeforeCopying() async throws {
        let root = try temporaryDirectory()
        let cache = root.appendingPathComponent("cache")
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: cache)
        await #expect(throws: HomeAttachmentError.typeRefused(mimeType: "image/svg+xml", name: "attachment.svg")) {
            try await store.prepareAttachment(data: Data("<svg/>".utf8), typeIdentifier: UTType.svg.identifier)
        }
        let script = root.appendingPathComponent("run.sh")
        try Data("echo".utf8).write(to: script)
        await #expect(throws: HomeAttachmentError.self) { try await store.prepareAttachment(fileURL: script) }

        // A sparse file one byte over the limit: refused from its size, never read.
        let big = root.appendingPathComponent("big.mp4")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(HomeAttachmentPolicy.maxBytes + 1))
        try handle.close()
        await #expect(throws: HomeAttachmentError.tooLarge(byteCount: HomeAttachmentPolicy.maxBytes + 1, limit: HomeAttachmentPolicy.maxBytes)) {
            try await store.prepareAttachment(fileURL: big)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @MainActor @Test func mimeTypesUseTheOwnersSpelling() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        // Not real audio: media facts are best effort, the file still prepares.
        let m4a = try await store.prepareAttachment(data: Data("not audio".utf8), typeIdentifier: UTType.mpeg4Audio.identifier)
        #expect(m4a.ref.mimeType == "audio/mp4")
        #expect(m4a.ref.durationMs == nil)
        let wav = try await store.prepareAttachment(data: Data("not wav".utf8), typeIdentifier: UTType.wav.identifier)
        #expect(wav.ref.mimeType == "audio/wav")
        for (name, mime) in [("notes.md", "text/markdown"), ("t.csv", "text/csv"), ("d.json", "application/json"),
                             ("a.zip", "application/zip"), ("s.mp3", "audio/mpeg"), ("h.heic", "image/heic")] {
            let file = root.appendingPathComponent(name)
            try Data("x\(name)".utf8).write(to: file)
            #expect(try await store.prepareAttachment(fileURL: file).ref.mimeType == mime)
        }
        #expect(HomeAttachmentPolicy.canonicalMimeType("audio/x-m4a") == "audio/mp4")
        #expect(AttachmentPreview.of([.text("hi")]) == nil)
    }

    @Test func attachmentRefWithoutNewFieldsDecodes() throws {
        let expected = AttachmentRef(hash: "abc", name: "a.png", mimeType: "image/png", byteCount: 3, width: 4, height: 5)
        let wire = Data(#"{"hash":"abc","name":"a.png","mime_type":"image/png","byte_count":3,"width":4,"height":5}"#.utf8)
        let ref = try JSONDecoder().decode(AttachmentRef.self, from: wire)
        #expect(ref == expected)
        #expect(ref.durationMs == nil)
        #expect(ref.posterHash == nil)
        // An earlier client encoded camelCase keys.
        let legacy = Data(#"{"hash":"abc","name":"a.png","mimeType":"image/png","byteCount":3,"width":4,"height":5}"#.utf8)
        #expect(try JSONDecoder().decode(AttachmentRef.self, from: legacy) == expected)

        let video = AttachmentRef(hash: "h", name: "v.mov", mimeType: "video/quicktime", byteCount: 9, width: 1, height: 2,
                                  durationMs: 1500, posterHash: "p")
        #expect(try JSONDecoder().decode(AttachmentRef.self, from: JSONEncoder().encode(video)) == video)
    }

    /// The owner's attachment part: hash, name, mime_type, byte_count,
    /// width?, height?, duration_ms?, poster_hash? (snake_case).
    @Test func attachmentRefEncodesTheWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let video = AttachmentRef(hash: "h", name: "v.mov", mimeType: "video/quicktime", byteCount: 9, width: 1, height: 2,
                                  durationMs: 1500, posterHash: "p")
        #expect(String(decoding: try encoder.encode(video), as: UTF8.self)
            == #"{"byte_count":9,"duration_ms":1500,"hash":"h","height":2,"mime_type":"video/quicktime","name":"v.mov","poster_hash":"p","width":1}"#)
        let file = AttachmentRef(hash: "h", name: "a.txt", mimeType: "text/plain", byteCount: 3)
        #expect(String(decoding: try encoder.encode(file), as: UTF8.self)
            == #"{"byte_count":3,"hash":"h","mime_type":"text/plain","name":"a.txt"}"#)
    }
}

@MainActor
@Suite struct AttachmentSendTests {
    let conversation = ConversationID("conv_austin")

    func started() async throws -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory())
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: conversation).isEmpty }
        return (store, source)
    }

    /// Waits on observation changes, never on a clock.
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<5_000 where !condition() { await Task.yield() }
    }

    func twoAttachments(_ store: HomeStore) async throws -> (LocalAttachment, LocalAttachment) {
        let a = try await store.prepareAttachment(data: Data("first".utf8), typeIdentifier: UTType.plainText.identifier)
        let b = try await store.prepareAttachment(data: Data("second".utf8), typeIdentifier: UTType.plainText.identifier)
        return (a, b)
    }

    @Test func sendShowsOnePendingRowWithFinalPartsAndProgressThenSettlesInPlace() async throws {
        let (store, source) = try await started()
        let (a, b) = try await twoAttachments(store)
        await source.setUploadsPaused(true)
        let key = IdempotencyKey("attach-send-1")
        let before = store.transcript(for: conversation).count
        let send = Task { try await store.send(conversation: conversation, text: "look", attachments: [a, b], key: key) }
        await waitUntil {
            let progress = store.transcript(for: self.conversation).last?.attachmentProgress ?? [:]
            return progress[a.ref.hash] == 0.5 && progress[b.ref.hash] == 0.5
        }

        let expectedParts: [MessagePart] = [.attachment(a.ref), .attachment(b.ref), .text("look")]
        let pending = store.transcript(for: conversation)
        #expect(pending.count == before + 1)
        let row = try #require(pending.last)
        #expect(row.id == key)
        #expect(row.delivery == .sending)
        #expect(row.parts == expectedParts)
        #expect(row.attachmentProgress == [a.ref.hash: 0.5, b.ref.hash: 0.5])
        #expect(row.localAttachments == [a.ref.hash: a.files, b.ref.hash: b.files])
        #expect(store.log.entries.map(\.intent.key) == [key])
        #expect(store.log.entries.first?.isUploading == true)

        await source.setUploadsPaused(false)
        try await send.value
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed }

        let settled = store.transcript(for: conversation)
        #expect(settled.count == before + 1)
        let committed = try #require(settled.last)
        #expect(committed.id == key)
        #expect(committed.delivery == .committed)
        #expect(committed.parts == expectedParts)
        #expect(committed.attachmentProgress.isEmpty)
        #expect(committed.localAttachments == [a.ref.hash: a.files, b.ref.hash: b.files])
        #expect(store.log.isEmpty)

        let page = try await source.snapshot(of: conversation, tail: 5)
        #expect(page.messages.last?.clientMessageID == key)
        #expect(page.messages.last?.parts == expectedParts)
        #expect(await source.uploadCalls.sorted() == [a.ref.hash, b.ref.hash].sorted())
    }

    @Test func attachmentOnlySendHasNoTextPart() async throws {
        let (store, _) = try await started()
        let (a, _) = try await twoAttachments(store)
        let key = IdempotencyKey("attach-only")
        try await store.send(conversation: conversation, text: "  \n", attachments: [a], key: key)
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed }
        #expect(store.transcript(for: conversation).last?.parts == [.attachment(a.ref)])
    }

    @Test func uploadFailureFailsTheRowAndRetryUploadsOnlyTheMissingAttachment() async throws {
        let (store, source) = try await started()
        let (a, b) = try await twoAttachments(store)
        await source.failNextUpload(hash: b.ref.hash)
        let key = IdempotencyKey("attach-fail")
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.send(conversation: conversation, text: "two", attachments: [a, b], key: key)
        }
        let failed = try #require(store.transcript(for: conversation).last)
        #expect(failed.id == key)
        #expect(failed.delivery == .notDelivered(.ownerUnreachable))
        #expect(failed.attachmentProgress.isEmpty)
        #expect(await source.hasBlob(a.ref.hash))
        #expect(await !source.hasBlob(b.ref.hash))

        try await store.retry(key)
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed }
        let committed = try #require(store.transcript(for: conversation).last)
        #expect(committed.id == key) // same key: the owner never saw the failed send
        #expect(committed.parts == [.attachment(a.ref), .attachment(b.ref), .text("two")])
        let calls = await source.uploadCalls
        #expect(calls.filter { $0 == a.ref.hash }.count == 1)
        #expect(calls.filter { $0 == b.ref.hash }.count == 2)
        #expect(store.log.isEmpty)
    }

    @Test func discardDropsAFailedUpload() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.failNextUpload(hash: a.ref.hash)
        let key = IdempotencyKey("attach-discard")
        let before = store.transcript(for: conversation).count
        _ = try? await store.send(conversation: conversation, text: "", attachments: [a], key: key)
        #expect(store.transcript(for: conversation).count == before + 1)
        store.discardFailed(key)
        #expect(store.transcript(for: conversation).count == before)
        #expect(store.log.isEmpty)
    }

    @Test func offlineSendIsRefusedAndLogsNothing() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.send(conversation: conversation, text: "x", attachments: [a])
        }
        #expect(store.log.isEmpty)
        #expect(await source.uploadCalls.isEmpty)
    }

    @Test func fetchIsIdempotentAndPrefersTheLocalCopy() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("p.jpg")
        try makeJPEG(width: 300, height: 100, orientation: 1).write(to: file)
        let photo = try await store.prepareAttachment(fileURL: file)
        try await store.send(conversation: conversation, text: "", attachments: [photo], key: IdempotencyKey("attach-fetch"))

        #expect(try await store.fetchAttachment(photo.ref, variant: .original) == photo.fileURL)
        let localThumb = try await store.fetchAttachment(photo.ref, variant: .thumbnail(maxPixel: 60))
        #expect(try await store.fetchAttachment(photo.ref, variant: .thumbnail(maxPixel: 60)) == localThumb)

        let here = AttachmentLocation(conversation: conversation)
        let first = try await source.fetch(photo.ref, at: here, variant: .original)
        let second = try await source.fetch(photo.ref, at: here, variant: .original)
        #expect(first == second)
        #expect(try Data(contentsOf: first) == Data(contentsOf: file))
        let thumb = try await source.fetch(photo.ref, at: here, variant: .thumbnail(maxPixel: 60))
        let thumbSource = try #require(CGImageSourceCreateWithURL(thumb as CFURL, nil))
        let thumbImage = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
        #expect(max(thumbImage.width, thumbImage.height) <= 60)
        await #expect(throws: HomeRejection.invalid("unknown_blob")) {
            try await source.fetch(AttachmentRef(hash: "missing", name: "", mimeType: "image/png", byteCount: 0), at: here, variant: .original)
        }
    }

    @Test func fetchWithoutALocalCopyNamesTheMessagePart() async throws {
        let (store, source) = try await started()
        let (a, b) = try await twoAttachments(store)
        try await store.send(conversation: conversation, text: "", attachments: [a, b], key: IdempotencyKey("attach-located"))
        let message = try #require(try await source.snapshot(of: conversation, tail: 1).messages.last)

        // Another client (no local copy) finds the part in its loaded transcript.
        let other = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory())
        other.start()
        await waitUntil { other.isOnline && !other.rows.isEmpty }
        await other.open(conversation)
        await waitUntil { other.transcript(for: self.conversation).last?.key == IdempotencyKey("attach-located") }
        #expect(other.transcript(for: conversation).last?.localAttachments.isEmpty == true)
        let url = try await other.fetchAttachment(b.ref, variant: .original)
        #expect(try Data(contentsOf: url) == Data("second".utf8))
        #expect(await source.fetchLocations.last == AttachmentLocation(conversation: conversation, message: message.id, partIndex: 1))
        await #expect(throws: HomeRejection.invalid("attachment_not_loaded")) {
            try await other.fetchAttachment(AttachmentRef(hash: "nowhere", name: "x", mimeType: "text/plain", byteCount: 1),
                                            variant: .original)
        }
    }

    @Test func inboxRowPreviewsAttachmentsWithoutTheirNames() async throws {
        let (store, _) = try await started()
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("p.jpg")
        try makeJPEG(width: 10, height: 10, orientation: 1).write(to: file)
        let photo = try await store.prepareAttachment(fileURL: file)
        let other = try await store.prepareAttachment(data: try makeJPEG(width: 12, height: 10, orientation: 1),
                                                      typeIdentifier: UTType.jpeg.identifier)
        try await store.send(conversation: conversation, text: "", attachments: [photo, other], key: IdempotencyKey("attach-row"))
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed }
        let row = try #require(store.rows.first { $0.id == self.conversation })
        #expect(row.preview == "")
        #expect(row.previewAttachments == AttachmentPreview(kind: .photo, count: 2))

        let (a, _) = try await twoAttachments(store)
        try await store.send(conversation: conversation, text: "notes", attachments: [photo, a], key: IdempotencyKey("attach-row-2"))
        await waitUntil { store.transcript(for: self.conversation).last?.key == IdempotencyKey("attach-row-2") }
        let mixed = try #require(store.rows.first { $0.id == self.conversation })
        #expect(mixed.preview == "notes")
        #expect(mixed.previewAttachments == AttachmentPreview(kind: .file, count: 2))
    }

    @Test func sendRefusesAFileTheOwnerWouldRefuseAndLogsNothing() async throws {
        let (store, source) = try await started()
        let svg = LocalAttachment(ref: AttachmentRef(hash: String(repeating: "a", count: 64), name: "x.svg",
                                                     mimeType: "image/svg+xml", byteCount: 10),
                                  fileURL: URL(fileURLWithPath: "/nonexistent/x.svg"))
        await #expect(throws: HomeAttachmentError.typeRefused(mimeType: "image/svg+xml", name: "x.svg")) {
            try await store.send(conversation: conversation, text: "x", attachments: [svg])
        }
        #expect(store.log.isEmpty)
        #expect(await source.uploadCalls.isEmpty)
    }

    @Test func sourcesWithoutBlobStorageRefuseAttachments() async throws {
        let source = LosingFirstAnswerSource(inner: MockHomeSource(options: .immediate))
        await #expect(throws: HomeRejection.invalid("attachments unsupported")) {
            try await source.fetch(AttachmentRef(hash: "h", name: "", mimeType: "", byteCount: 0),
                                   at: AttachmentLocation(conversation: ConversationID("c")), variant: .original)
        }
    }
}
