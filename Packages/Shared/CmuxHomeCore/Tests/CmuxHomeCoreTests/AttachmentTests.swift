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
        let meta = try #require(prepared.ref.poster)
        let posterData = try Data(contentsOf: poster)
        #expect(meta == AttachmentPoster(hash: sha256Hex(posterData), mimeType: "image/jpeg", byteCount: posterData.count))
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
                                  durationMs: 1500, poster: AttachmentPoster(hash: "p", mimeType: "image/jpeg", byteCount: 7))
        #expect(try JSONDecoder().decode(AttachmentRef.self, from: JSONEncoder().encode(video)) == video)
        // The owner may record a WebP poster.
        let webp = Data(#"{"hash":"h","name":"v.mp4","mime_type":"video/mp4","byte_count":9,"poster":{"hash":"w","mime_type":"image/webp","byte_count":5}}"#.utf8)
        #expect(try JSONDecoder().decode(AttachmentRef.self, from: webp).poster
            == AttachmentPoster(hash: "w", mimeType: "image/webp", byteCount: 5))
    }

    /// The owner's attachment part: hash, name, mime_type, byte_count,
    /// width?, height?, duration_ms?, poster? {hash, mime_type, byte_count}
    /// (snake_case; `poster_hash` is gone).
    @Test func attachmentRefEncodesTheWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let video = AttachmentRef(hash: "h", name: "v.mov", mimeType: "video/quicktime", byteCount: 9, width: 1, height: 2,
                                  durationMs: 1500, poster: AttachmentPoster(hash: "p", mimeType: "image/jpeg", byteCount: 7))
        #expect(String(decoding: try encoder.encode(video), as: UTF8.self)
            == #"{"byte_count":9,"duration_ms":1500,"hash":"h","height":2,"mime_type":"video/quicktime","name":"v.mov","poster":{"byte_count":7,"hash":"p","mime_type":"image/jpeg"},"width":1}"#)
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

    /// Lets queued main-actor and source tasks run (for "nothing happens" checks).
    func drainTasks() async {
        for _ in 0..<500 { await Task.yield() }
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
        await #expect(throws: HomeRejection.invalid("attachment_upload_failed")) {
            try await store.send(conversation: conversation, text: "two", attachments: [a, b], key: key)
        }
        let failed = try #require(store.transcript(for: conversation).last)
        #expect(failed.id == key)
        #expect(failed.delivery == .notDelivered(.invalid("attachment_upload_failed")))
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

    /// `cancelSend` stops an upload in flight and drops the row; nothing
    /// reaches the owner.
    @Test func cancelSendStopsTheUploadAndDiscardsTheRow() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.setUploadsPaused(true)
        let key = IdempotencyKey("attach-cancel")
        let before = store.transcript(for: conversation).count
        let send = Task { try await store.send(conversation: conversation, text: "big", attachments: [a], key: key) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        #expect(store.cancelSend(key))
        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(store.transcript(for: conversation).count == before)
        #expect(store.log.isEmpty)
        await source.setUploadsPaused(false)
        #expect(await !source.hasBlob(a.ref.hash))
        #expect(try await source.snapshot(of: conversation, tail: 5).messages.allSatisfy { $0.clientMessageID != key })
        #expect(!store.cancelSend(key))
    }

    /// The connection drops mid-upload: the row stays "sending" (not "Not
    /// Delivered"), and the upload resumes on reconnect and sends once.
    @Test func disconnectMidUploadResumesOnReconnectAndSendsOnce() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.setUploadsPaused(true)
        let key = IdempotencyKey("attach-reconnect")
        let send = Task { try await store.send(conversation: conversation, text: "later", attachments: [a], key: key) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        await source.setUploadsPaused(false)
        await #expect(throws: HomeSendState.pendingResend) { try await send.value }
        let waiting = try #require(store.transcript(for: conversation).last)
        #expect(waiting.id == key)
        #expect(waiting.delivery == .sending)
        #expect(await !source.hasBlob(a.ref.hash))

        await source.setOnline(true)
        await waitUntil { store.log.isEmpty }
        #expect(store.log.isEmpty)
        #expect(store.transcript(for: conversation).last?.id == key)
        #expect(store.transcript(for: conversation).last?.delivery == .committed)
        let page = try await source.snapshot(of: conversation, tail: 10)
        #expect(page.messages.filter { $0.clientMessageID == key }.count == 1)
        #expect(await source.uploadCalls.filter { $0 == a.ref.hash }.count == 2)
    }

    /// A progress callback that arrives after its upload failed, or from an
    /// earlier attempt during a retry, changes nothing.
    @Test func lateProgressFromAnEndedUploadIsIgnored() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.failNextUpload(hash: a.ref.hash)
        let key = IdempotencyKey("attach-late-progress")
        _ = try? await store.send(conversation: conversation, text: "", attachments: [a], key: key)
        #expect(store.transcript(for: conversation).last?.delivery == .notDelivered(.invalid("attachment_upload_failed")))
        await source.replayProgress(ofCall: 0, 0.9)
        await drainTasks()
        #expect(store.transcript(for: conversation).last?.attachmentProgress.isEmpty == true)

        await source.setUploadsPaused(true)
        let retry = Task { try await store.retry(key) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        await source.replayProgress(ofCall: 0, 0.9)
        await drainTasks()
        #expect(store.transcript(for: conversation).last?.attachmentProgress == [a.ref.hash: 0.5])
        await source.setUploadsPaused(false)
        try await retry.value
        await waitUntil { store.log.isEmpty }
        #expect(store.transcript(for: conversation).last?.delivery == .committed)
    }

    /// A paused upload stops when its task is cancelled.
    @Test(.timeLimit(.minutes(1))) func mockUploadHonorsCancellation() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.setUploadsPaused(true)
        let conversation = self.conversation
        let upload = Task { try await source.upload(AttachmentUpload(conversation: conversation, fileURL: a.fileURL, ref: a.ref)) }
        await drainTasks()
        upload.cancel()
        await #expect(throws: CancellationError.self) { try await upload.value }
        #expect(await !source.hasBlob(a.ref.hash))
    }

    /// Sends reach the owner in the order the user made them, per
    /// conversation: a text sent while an earlier photo uploads waits for it.
    @Test func aTextSentDuringAnUploadDoesNotOvertakeIt() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.setUploadsPaused(true)
        let photoKey = IdempotencyKey("attach-order-photo")
        let textKey = IdempotencyKey("attach-order-text")
        let photo = Task { try await store.send(conversation: conversation, text: "", attachments: [a], key: photoKey) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        let conversation = self.conversation
        let text = Task { try await store.perform(.sendMessage(conversation: conversation, parts: [.text("after")]), key: textKey) }
        await drainTasks()
        #expect(store.transcript(for: conversation).suffix(2).map(\.id) == [photoKey, textKey])
        #expect(try await source.snapshot(of: conversation, tail: 5).messages.allSatisfy { $0.clientMessageID != textKey })

        await source.setUploadsPaused(false)
        try await photo.value
        _ = try await text.value
        await waitUntil { store.log.isEmpty }
        let page = try await source.snapshot(of: conversation, tail: 5)
        let photoSeq = try #require(page.messages.first { $0.clientMessageID == photoKey }?.seq)
        let textSeq = try #require(page.messages.first { $0.clientMessageID == textKey }?.seq)
        #expect(photoSeq < textSeq)
        #expect(store.transcript(for: conversation).suffix(2).map(\.id) == [photoKey, textKey])
    }

    /// A failed upload does not hold later sends back.
    @Test func aFailedUploadDoesNotBlockLaterSends() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.failNextUpload(hash: a.ref.hash)
        _ = try? await store.send(conversation: conversation, text: "", attachments: [a], key: IdempotencyKey("attach-order-failed"))
        let textKey = IdempotencyKey("attach-order-next")
        _ = try await store.perform(.sendMessage(conversation: conversation, parts: [.text("next")]), key: textKey)
        #expect(try await source.snapshot(of: conversation, tail: 5).messages.last?.clientMessageID == textKey)
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

    /// One part per video; its poster is fetched with `.poster` (the
    /// route's `variant=poster`), not as a part of its own.
    @Test func posterVariantFetchesTheVideosPosterFrame() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 128, height: 64)
        let video = try await store.prepareAttachment(fileURL: movie)
        let meta = try #require(video.ref.poster)
        let posterFile = try #require(video.posterURL)
        try await store.send(conversation: conversation, text: "", attachments: [video], key: IdempotencyKey("attach-poster"))
        #expect(try await source.snapshot(of: conversation, tail: 1).messages.last?.parts == [.attachment(video.ref)])

        #expect(try await store.fetchAttachment(video.ref, variant: .poster) == posterFile)
        let here = AttachmentLocation(conversation: conversation)
        let fetched = try await source.fetch(video.ref, at: here, variant: .poster)
        #expect(try await source.fetch(video.ref, at: here, variant: .poster) == fetched)
        let bytes = try Data(contentsOf: fetched)
        #expect(bytes.count == meta.byteCount)
        #expect(sha256Hex(bytes) == meta.hash)

        var noPoster = video.ref
        noPoster.poster = nil
        await #expect(throws: HomeRejection.invalid("no_poster")) {
            try await source.fetch(noPoster, at: here, variant: .poster)
        }
    }

    /// A declared poster must land before the video (the owner's 409
    /// `attachment.poster_missing`).
    @Test func uploadRefusesADeclaredPosterWithoutItsBytes() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 64, height: 64)
        let video = try await store.prepareAttachment(fileURL: movie)
        #expect(video.ref.poster != nil)
        await #expect(throws: HomeRejection.invalid("poster_missing")) {
            try await source.upload(AttachmentUpload(conversation: conversation, fileURL: video.fileURL, ref: video.ref))
        }
        await #expect(throws: HomeRejection.invalid("unknown_blob")) {
            try await source.fetch(video.ref, at: AttachmentLocation(conversation: conversation), variant: .original)
        }
    }

    /// Another device uploaded the same video first, with its own poster
    /// and as `video/mp4`. The owner keeps the first record, so the send
    /// carries the record's mime type and poster, not this device's.
    @Test func existsWithADifferentPosterAdoptsTheOwnersRecord() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 128, height: 64)
        let video = try await store.prepareAttachment(fileURL: movie)
        let localPoster = try #require(video.ref.poster)
        let otherData = try makeJPEG(width: 16, height: 32, orientation: 1)
        let otherURL = root.appendingPathComponent("other-poster.jpg")
        try otherData.write(to: otherURL)
        let other = AttachmentPoster(hash: sha256Hex(otherData), mimeType: "image/jpeg", byteCount: otherData.count)
        #expect(other != localPoster)
        var first = video.ref
        first.mimeType = "video/mp4"
        first.poster = other
        _ = try await source.upload(AttachmentUpload(conversation: conversation, fileURL: video.fileURL, ref: first,
                                                     posterURL: otherURL))

        let key = IdempotencyKey("attach-exists-other-poster")
        let before = store.transcript(for: conversation).count
        try await store.send(conversation: conversation, text: "same clip", attachments: [video], key: key)
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed }
        var expected = video.ref
        expected.mimeType = "video/mp4"
        expected.poster = other
        let parts: [MessagePart] = [.attachment(expected), .text("same clip")]
        let rows = store.transcript(for: conversation)
        #expect(rows.count == before + 1)
        #expect(rows.last?.id == key)
        #expect(rows.last?.delivery == .committed)
        #expect(rows.last?.parts == parts)
        #expect(store.log.isEmpty)
        #expect(try await source.snapshot(of: conversation, tail: 1).messages.last?.parts == parts)
        // The poster shown is the recorded one, not this device's frame.
        let poster = try await store.fetchAttachment(expected, at: AttachmentLocation(conversation: conversation),
                                                     variant: .poster)
        #expect(sha256Hex(try Data(contentsOf: poster)) == other.hash)
    }

    /// The first upload of the video recorded no poster (extraction failed
    /// there): the part must not claim one.
    @Test func existsWithNoPosterSendsThePartWithoutAPoster() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 64, height: 64)
        let video = try await store.prepareAttachment(fileURL: movie)
        #expect(video.ref.poster != nil)
        var first = video.ref
        first.poster = nil
        _ = try await source.upload(AttachmentUpload(conversation: conversation, fileURL: video.fileURL, ref: first))

        let key = IdempotencyKey("attach-exists-no-poster")
        try await store.send(conversation: conversation, text: "", attachments: [video], key: key)
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed }
        let committed = try #require(store.transcript(for: conversation).last)
        #expect(committed.id == key)
        #expect(committed.parts == [.attachment(first)])
        #expect(try await source.snapshot(of: conversation, tail: 1).messages.last?.parts == [.attachment(first)])
        await #expect(throws: HomeRejection.invalid("no_poster")) {
            try await store.fetchAttachment(first, at: AttachmentLocation(conversation: conversation), variant: .poster)
        }
    }

    /// The owner swept the upload before the send reached it (an
    /// unreferenced upload after 24 hours, an expired slot): the store
    /// uploads again (an exists answer when the bytes are still there) and
    /// sends again under a new key, since the owner's ledger keeps the
    /// refused one.
    @Test func unknownAttachmentUploadsAgainAndResends() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.forgetBlobBeforeNextSubmits(a.ref.hash)
        let before = store.transcript(for: conversation).count
        try await store.send(conversation: conversation, text: "swept", attachments: [a], key: IdempotencyKey("attach-swept"))
        await waitUntil { store.log.isEmpty }
        let rows = store.transcript(for: conversation)
        #expect(rows.count == before + 1)
        #expect(rows.last?.delivery == .committed)
        #expect(rows.last?.parts == [.attachment(a.ref), .text("swept")])
        #expect(store.log.isEmpty)
        #expect(await source.uploadCalls.filter { $0 == a.ref.hash }.count == 2)
        let page = try await source.snapshot(of: conversation, tail: 5)
        #expect(page.messages.filter { $0.parts == [.attachment(a.ref), .text("swept")] }.count == 1)
    }

    /// Refused again after the automatic upload: "Not Delivered", and
    /// `retry` still holds the upload job, so it uploads before sending.
    @Test func retryAfterUnknownAttachmentUploadsAgain() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        await source.forgetBlobBeforeNextSubmits(a.ref.hash, times: 2)
        let key = IdempotencyKey("attach-swept-twice")
        await #expect(throws: HomeRejection.invalid("unknown_attachment")) {
            try await store.send(conversation: conversation, text: "", attachments: [a], key: key)
        }
        let failed = try #require(store.transcript(for: conversation).last)
        #expect(failed.delivery == .notDelivered(.invalid("unknown_attachment")))
        #expect(failed.parts == [.attachment(a.ref)])
        #expect(await !source.hasBlob(a.ref.hash))

        try await store.retry(failed.id)
        await waitUntil { store.log.isEmpty }
        #expect(store.transcript(for: conversation).last?.delivery == .committed)
        #expect(store.transcript(for: conversation).last?.parts == [.attachment(a.ref)])
        #expect(await source.hasBlob(a.ref.hash))
        #expect(await source.uploadCalls.filter { $0 == a.ref.hash }.count == 3)
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
