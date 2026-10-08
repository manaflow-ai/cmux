import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Testing
import CmuxHomeCoreTestSupport
import UniformTypeIdentifiers
@testable import CmuxHomeCore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-attach-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A `width` x `height` JPEG whose EXIF orientation is `orientation`.
func makeJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
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

/// A `width` x `height` image of `type` (TIFF, HEIF), with or without alpha.
func makeImage(type: UTType, width: Int, height: Int, alpha: Bool) throws -> Data {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: alpha ? 0.5 : 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A JPEG with EXIF orientation `orientation` (6 by default) and a GPS position.
func makeJPEGWithLocation(width: Int, height: Int, orientation: Int = 6) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W",
    ]
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImagePropertyGPSDictionary: gps] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

func hasGPS(_ url: URL) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return properties[kCGImagePropertyGPSDictionary] != nil
}

func movieHasLocation(_ url: URL) async throws -> Bool {
    let items = try await AVURLAsset(url: url).load(.metadata)
    return items.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.identifier == .commonIdentifierLocation
        || $0.identifier == .quickTimeUserDataLocationISO6709 }
}

/// A one-second H.264 movie, `width` x `height` encoded, rotated 90 degrees
/// by its track transform (display size is `height` x `width`).
func makeMovie(at url: URL, width: Int, height: Int, frames: Int = 10, fps: Int32 = 10,
                       location: String? = nil, locationName: String? = nil, trackLocation: String? = nil,
                       timedLocation: String? = nil,
                       timedIdentifier: AVMetadataIdentifier = .quickTimeMetadataLocationISO6709,
                       subtitle: String? = nil) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = value as NSString
        return item
    }
    var assetItems: [AVMetadataItem] = []
    if let location { assetItems.append(item(.quickTimeMetadataLocationISO6709, location)) }
    if let locationName { assetItems.append(item(.quickTimeMetadataLocationName, locationName)) }
    writer.metadata = assetItems
    // A timed metadata track of positions (a GoPro or drone GPS track).
    var timedInput: AVAssetWriterInput?
    var timedAdaptor: AVAssetWriterInputMetadataAdaptor?
    // A location identifier carries ISO 6709 data; any other (an iPhone's
    // orientation or still-image-time track) carries UTF-8 text here.
    let timedDataType = timedIdentifier == .quickTimeMetadataLocationISO6709
        ? kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String : kCMMetadataBaseDataType_UTF8 as String
    if timedLocation != nil {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: timedIdentifier.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: timedDataType,
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
                                                                    metadataSpecifications: [spec] as CFArray,
                                                                    formatDescriptionOut: &description)
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        timedAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        writer.add(input)
        timedInput = input
    }
    // A 3GPP text track (a drone writes its GPS as subtitles).
    var textInput: AVAssetWriterInput?
    var textFormat: CMFormatDescription?
    if subtitle != nil {
        textFormat = try makeTextFormatDescription()
        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        input.expectsMediaDataInRealTime = false
        try #require(writer.canAdd(input), "the writer must take a text track")
        writer.add(input)
        textInput = input
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    if let trackLocation { input.metadata = [item(.quickTimeMetadataLocationISO6709, trackLocation)] }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting(), "AVAssetWriter could not start: \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    if let timedLocation, let timedInput, let timedAdaptor {
        let point = AVMutableMetadataItem()
        point.identifier = timedIdentifier
        point.dataType = timedDataType
        point.value = timedLocation as NSString
        let group = AVTimedMetadataGroup(items: [point], timeRange: CMTimeRange(start: .zero,
                                                                                duration: CMTime(value: CMTimeValue(frames), timescale: fps)))
        while !timedInput.isReadyForMoreMediaData { await Task.yield() }
        #expect(timedAdaptor.append(group))
        timedInput.markAsFinished()
    }
    if let subtitle, let textInput, let textFormat {
        let sample = try makeTextSample(subtitle, format: textFormat,
                                        duration: CMTime(value: CMTimeValue(frames), timescale: fps))
        while !textInput.isReadyForMoreMediaData { await Task.yield() }
        #expect(textInput.append(sample))
        textInput.markAsFinished()
    }
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

/// A 3GPP timed text format: the extensions the format requires.
func makeTextFormatDescription() throws -> CMFormatDescription {
    let white: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                                  kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255]
    let clear: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                                  kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 0]
    let extensions: [CFString: Any] = [
        kCMTextFormatDescriptionExtension_DisplayFlags: 0,
        kCMTextFormatDescriptionExtension_BackgroundColor: clear,
        kCMTextFormatDescriptionExtension_DefaultTextBox: [
            kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
            kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
        ] as [CFString: Any],
        kCMTextFormatDescriptionExtension_DefaultStyle: [
            kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
            kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
            kCMTextFormatDescriptionStyle_FontSize: 12, kCMTextFormatDescriptionStyle_ForegroundColor: white,
        ] as [CFString: Any],
        kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
        kCMTextFormatDescriptionExtension_VerticalJustification: 0,
        kCMTextFormatDescriptionExtension_FontTable: ["1": "Helvetica"],
    ]
    var format: CMFormatDescription?
    let status = CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
                                           extensions: extensions as CFDictionary, formatDescriptionOut: &format)
    #expect(status == noErr)
    return try #require(format)
}

/// One 3GPP text sample: a big-endian length, then the UTF-8 text.
func makeTextSample(_ text: String, format: CMFormatDescription, duration: CMTime) throws -> CMSampleBuffer {
    let utf8 = Array(text.utf8)
    let bytes = [UInt8(utf8.count >> 8 & 0xff), UInt8(utf8.count & 0xff)] + utf8
    var block: CMBlockBuffer?
    #expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                               flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr)
    let buffer = try #require(block)
    #expect(bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: buffer,
                                                                   offsetIntoDestination: 0, dataLength: bytes.count) } == noErr)
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var size = bytes.count
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReady(allocator: nil, dataBuffer: buffer, formatDescription: format, sampleCount: 1,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                      sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
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

    /// Start-up cleanup: crash leftovers go, blobs older than the age limit
    /// go unless a pending send uses them, then the least recently used go
    /// until the cache fits the size cap.
    @MainActor @Test func blobCachePruneRemovesTempOldAndOverCapBlobs() async throws {
        let root = try temporaryDirectory()
        let fm = FileManager.default
        let now = Date()
        func blob(_ name: String, bytes: Int, age: TimeInterval) throws {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: dir.appendingPathComponent("data.txt"))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: dir.path)
        }
        try Data("partial".utf8).write(to: root.appendingPathComponent(".incoming-\(UUID().uuidString)"))
        try blob("old", bytes: 10, age: 10 * 86_400)
        try blob("pendingold", bytes: 10, age: 10 * 86_400)
        try blob("a", bytes: 40, age: 3 * 3_600)
        try blob("b", bytes: 40, age: 2 * 3_600)
        try blob("c", bytes: 40, age: 1 * 3_600)

        await HomeStore.pruneBlobCache(at: root, keeping: ["pendingold"], now: now, maxAge: 7 * 86_400, maxBytes: 100,
                                       tempsBefore: .distantFuture)
        let left = Set(try fm.contentsOfDirectory(atPath: root.path))
        #expect(left == ["pendingold", "b", "c"])

        // The store's own pass deletes temp files from before it started
        // (a crash) and keeps what it prepared.
        try Data("partial".utf8).write(to: root.appendingPathComponent(".incoming-\(UUID().uuidString)"))
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let prepared = try await store.prepareAttachment(data: Data("fresh".utf8), typeIdentifier: UTType.plainText.identifier)
        await store.pruneBlobCache(now: now)
        #expect(fm.fileExists(atPath: prepared.fileURL.path))
        #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".incoming-") })
    }

    /// A pasted macOS screenshot is TIFF, an iPhone photo can be HEIF:
    /// neither is on the owner's allow list, so the core converts them, PNG
    /// when the image has alpha, else JPEG.
    @MainActor @Test func tiffAndHEIFAreConvertedBeforeThePolicy() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let screenshot = try makeImage(type: .tiff, width: 30, height: 20, alpha: true)
        let pasted = try await store.prepareAttachment(data: screenshot, typeIdentifier: UTType.tiff.identifier)
        #expect(pasted.ref.mimeType == "image/png")
        #expect(pasted.ref.name == "attachment.png")
        #expect(pasted.ref.width == 30 && pasted.ref.height == 20)
        let bytes = try Data(contentsOf: pasted.fileURL)
        #expect(pasted.ref.hash == sha256Hex(bytes))
        #expect(pasted.ref.byteCount == bytes.count)
        let decoded = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)

        let opaque = try makeImage(type: .tiff, width: 12, height: 8, alpha: false)
        let file = root.appendingPathComponent("Screen Shot.tiff")
        try opaque.write(to: file)
        let dropped = try await store.prepareAttachment(fileURL: file)
        #expect(dropped.ref.mimeType == "image/jpeg")
        #expect(dropped.ref.name == "Screen Shot.jpg")
        #expect(dropped.ref.width == 12 && dropped.ref.height == 8)

        // HEIF only where ImageIO can write it (to make the test input).
        let heifType = try #require(UTType("public.heif"))
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if writable.contains(heifType.identifier) {
            let heif = try makeImage(type: heifType, width: 16, height: 16, alpha: false)
            let photo = try await store.prepareAttachment(data: heif, typeIdentifier: heifType.identifier)
            #expect(photo.ref.mimeType == "image/jpeg")
        }
    }

    /// The owner's name rules: 1 to 255 characters, no control characters
    /// or path separators, not blank, `.` or `..`, and no denied extension
    /// whatever the type.
    @Test func namesFollowTheOwnersRules() throws {
        let longest = String(repeating: "\u{E9}", count: 251) + ".txt"
        try HomeAttachmentPolicy.check(mimeType: "text/plain", byteCount: 1, name: longest)
        for bad in [longest + "x", "a\u{7}.txt", "a\u{2028}.txt", "a/b.txt", "a\\b.txt", " ", ".", "..", ""] {
            #expect(throws: HomeAttachmentError.invalidName(name: bad)) {
                try HomeAttachmentPolicy.check(mimeType: "text/plain", byteCount: 1, name: bad)
            }
        }
        for denied in ["run.sh", "app.JS", "page.html", "x.svg", "Setup.dmg", "tool.exe"] {
            #expect(throws: HomeAttachmentError.typeRefused(mimeType: "text/plain", name: denied)) {
                try HomeAttachmentPolicy.check(mimeType: "text/plain", byteCount: 1, name: denied)
            }
        }
        // A file's own name is made valid before the check.
        #expect(HomeAttachmentPolicy.sendableName("a\u{1}b/c.txt") == "a_b_c.txt")
        let trimmed = HomeAttachmentPolicy.sendableName(String(repeating: "n", count: 300) + ".txt")
        #expect(trimmed.unicodeScalars.count == 255)
        #expect(trimmed.hasSuffix(".txt"))
        #expect(HomeAttachmentPolicy.sendableName("  ") == "attachment")
    }

    /// The copy into the cache stops one byte past the limit (the file grew
    /// after its size was read), and leaves nothing behind.
    @Test func ingestStopsCopyingPastTheLimit() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("growing.txt")
        try Data(repeating: 1, count: 100).write(to: source)
        let cache = root.appendingPathComponent("cache")
        #expect(throws: HomeAttachmentError.tooLarge(byteCount: 11, limit: 10)) {
            try AttachmentMedia.ingest(fileURL: source, root: cache, maxBytes: 10)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    /// Sample bytes prepare can take for `type`: a real image for a type
    /// that is converted (when ImageIO can write one), else any bytes.
    func sampleInput(for type: UTType) throws -> Data? {
        let mime = HomeAttachmentPolicy.canonicalMimeType(type.preferredMIMEType ?? "")
        guard type.conforms(to: .image), HomeAttachmentPolicy.allowedTypes[mime] == nil else {
            return Data("sample \(type.identifier)".utf8)
        }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(type.identifier),
              let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        // Some writers need sizes or depths this sample lacks: no sample then.
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    /// The composer's pre-check (`accepts`) says yes exactly when prepare
    /// takes the input.
    @MainActor @Test func acceptedInputTypesMatchPrepare() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let accepted = HomeAttachmentPolicy.acceptedInputTypes
        #expect(accepted.isSuperset(of: [UTType.jpeg.identifier, UTType.png.identifier, UTType.pdf.identifier,
                                         UTType.plainText.identifier, UTType.mpeg4Movie.identifier, UTType.tiff.identifier]))
        var prepared = 0
        for identifier in accepted.sorted() {
            let type = try #require(UTType(identifier))
            #expect(HomeAttachmentPolicy.accepts(typeIdentifier: identifier), "\(identifier)")
            guard let sample = try sampleInput(for: type) else { continue }
            do {
                _ = try await store.prepareAttachment(data: sample, typeIdentifier: identifier)
                prepared += 1
            } catch {
                Issue.record("accepted \(identifier) but prepare refused it: \(error)")
            }
        }
        #expect(prepared >= HomeAttachmentPolicy.allowedTypes.count)

        // Other types: both answers agree, whatever they are.
        for identifier in ["public.utf8-plain-text", "public.swift-source", "public.html", "public.xml", "com.microsoft.bmp",
                           "public.svg-image", "com.apple.application-bundle", "public.data", "public.image"] {
            guard let type = UTType(identifier), let sample = try sampleInput(for: type) else { continue }
            let prepares = (try? await store.prepareAttachment(data: sample, typeIdentifier: identifier)) != nil
            #expect(HomeAttachmentPolicy.accepts(typeIdentifier: identifier) == prepares, "\(identifier)")
        }
        // A refused type, refused by both.
        #expect(!HomeAttachmentPolicy.accepts(typeIdentifier: UTType.svg.identifier))
        await #expect(throws: HomeAttachmentError.self) {
            try await store.prepareAttachment(data: Data("<svg/>".utf8), typeIdentifier: UTType.svg.identifier)
        }
        // Files: the extension decides, as in prepare(fileURL:).
        let script = root.appendingPathComponent("run.sh")
        try Data("echo".utf8).write(to: script)
        #expect(!HomeAttachmentPolicy.accepts(fileURL: script))
        await #expect(throws: HomeAttachmentError.self) { try await store.prepareAttachment(fileURL: script) }
        #expect(HomeAttachmentPolicy.accepts(fileURL: root.appendingPathComponent("Screen Shot.tiff")))
        #expect(HomeAttachmentPolicy.accepts(fileURL: root.appendingPathComponent("notes.md")))
    }

    /// Location is stripped by default (the host's
    /// `home.attachments.keepLocation` setting is off): the uploaded bytes
    /// have no GPS, the hash is of those bytes, orientation stays.
    @MainActor @Test func photoLocationIsStrippedUnlessKept() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let original = try makeJPEGWithLocation(width: 40, height: 20)
        let file = root.appendingPathComponent("IMG_0001.jpg")
        try original.write(to: file)
        #expect(try hasGPS(file))

        let stripped = try await store.prepareAttachment(fileURL: file)
        #expect(try !hasGPS(stripped.fileURL))
        let bytes = try Data(contentsOf: stripped.fileURL)
        #expect(stripped.ref.hash == sha256Hex(bytes))
        #expect(stripped.ref.hash != sha256Hex(original))
        #expect(stripped.ref.byteCount == bytes.count)
        #expect(stripped.ref.name == "IMG_0001.jpg")
        #expect(stripped.ref.mimeType == "image/jpeg")
        #expect(stripped.ref.width == 20 && stripped.ref.height == 40) // orientation 6 kept

        let pasted = try await store.prepareAttachment(data: original, typeIdentifier: UTType.jpeg.identifier)
        #expect(try !hasGPS(pasted.fileURL))
        #expect(pasted.ref.hash == sha256Hex(try Data(contentsOf: pasted.fileURL)))

        let kept = try await store.prepareAttachment(fileURL: file, keepLocation: true)
        #expect(try hasGPS(kept.fileURL))
        #expect(kept.ref.hash == sha256Hex(original))
        let keptPaste = try await store.prepareAttachment(data: original, typeIdentifier: UTType.jpeg.identifier, keepLocation: true)
        #expect(keptPaste.ref.hash == sha256Hex(original))

        // A photo without location keeps its exact bytes.
        let plain = try makeJPEG(width: 10, height: 10, orientation: 1)
        #expect(try await store.prepareAttachment(data: plain, typeIdentifier: UTType.jpeg.identifier).ref.hash == sha256Hex(plain))
    }

    /// The same for a video's location metadata (a passthrough export, no
    /// re-encode).
    @MainActor @Test func videoLocationIsStrippedUnlessKept() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 64, height: 32, location: "+37.3349-122.0090/")
        #expect(try await movieHasLocation(movie))

        let stripped = try await store.prepareAttachment(fileURL: movie)
        #expect(try await !movieHasLocation(stripped.fileURL))
        #expect(stripped.ref.hash == sha256Hex(try Data(contentsOf: stripped.fileURL)))
        #expect(stripped.ref.mimeType == "video/quicktime")
        #expect(stripped.ref.width == 32 && stripped.ref.height == 64)
        #expect(stripped.ref.poster != nil)

        let kept = try await store.prepareAttachment(fileURL: movie, keepLocation: true)
        #expect(try await movieHasLocation(kept.fileURL))
        #expect(kept.ref.hash == sha256Hex(try Data(contentsOf: movie)))
    }

    /// An image over 1024 px (or a HEIC) gets a JPEG preview, declared on
    /// the part like a video's poster; a small one does not.
    @MainActor @Test func largeImagesGetAJPEGPreviewSmallOnesDoNot() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let photo = try await store.prepareAttachment(data: try makeJPEG(width: 2400, height: 1200, orientation: 6),
                                                      typeIdentifier: UTType.jpeg.identifier)
        let meta = try #require(photo.ref.preview)
        let previewURL = try #require(photo.previewURL)
        let bytes = try Data(contentsOf: previewURL)
        #expect(meta == AttachmentDerivedImage(hash: sha256Hex(bytes), mimeType: "image/jpeg", byteCount: bytes.count))
        #expect(bytes.count <= HomeAttachmentPolicy.previewMaxBytes)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= HomeAttachmentPolicy.previewMaxPixel)
        #expect(image.height > image.width) // orientation applied
        #expect(photo.files.previewURL == previewURL)

        let small = try await store.prepareAttachment(data: try makeJPEG(width: 40, height: 20, orientation: 1),
                                                      typeIdentifier: UTType.jpeg.identifier)
        #expect(small.ref.preview == nil)
        #expect(small.previewURL == nil)
    }

    @Test func previewEncodesAsItsOwnPartKey() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let photo = AttachmentRef(hash: "h", name: "p.heic", mimeType: "image/heic", byteCount: 9, width: 3, height: 4,
                                  preview: AttachmentDerivedImage(hash: "q", mimeType: "image/jpeg", byteCount: 5))
        #expect(String(decoding: try encoder.encode(photo), as: UTF8.self)
            == #"{"byte_count":9,"hash":"h","height":4,"mime_type":"image/heic","name":"p.heic","preview":{"byte_count":5,"hash":"q","mime_type":"image/jpeg"},"width":3}"#)
        #expect(try JSONDecoder().decode(AttachmentRef.self, from: encoder.encode(photo)) == photo)
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
        let conversation = self.conversation
        let photo = Task { try await store.send(conversation: conversation, text: "", attachments: [a], key: photoKey) }
        await waitUntil { store.transcript(for: conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
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

        #expect(try await store.fetchAttachment(photo.ref, variant: .original, in: conversation) == photo.fileURL)
        let localThumb = try await store.fetchAttachment(photo.ref, variant: .thumbnail(maxPixel: 60), in: conversation)
        #expect(try await store.fetchAttachment(photo.ref, variant: .thumbnail(maxPixel: 60), in: conversation) == localThumb)

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

        #expect(try await store.fetchAttachment(video.ref, variant: .poster, in: conversation) == posterFile)
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

    /// The OS purged the blob cache (iOS can): the local copy is skipped
    /// and the bytes come from the source.
    @Test func fetchFallsBackToTheSourceWhenTheCachedFileIsGone() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("p.jpg")
        try makeJPEG(width: 300, height: 100, orientation: 1).write(to: file)
        let photo = try await store.prepareAttachment(fileURL: file)
        try await store.send(conversation: conversation, text: "", attachments: [photo], key: IdempotencyKey("attach-purged"))
        try FileManager.default.removeItem(at: photo.fileURL.deletingLastPathComponent())

        let here = AttachmentLocation(conversation: conversation)
        let original = try await store.fetchAttachment(photo.ref, at: here, variant: .original)
        #expect(original != photo.fileURL)
        #expect(try Data(contentsOf: original) == Data(contentsOf: file))
        let thumb = try await store.fetchAttachment(photo.ref, at: here, variant: .thumbnail(maxPixel: 40))
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        #expect(await source.fetchLocations.count >= 2)
        #expect(store.transcript(for: conversation).last?.localAttachments.isEmpty == true)
    }

    /// A pending upload whose cached file was purged fails with a code that
    /// says so, without calling the source.
    @Test func aPurgedPendingFileFailsClearly() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        try FileManager.default.removeItem(at: a.fileURL)
        let key = IdempotencyKey("attach-purged-pending")
        await #expect(throws: HomeRejection.invalid("attachment_file_missing")) {
            try await store.send(conversation: conversation, text: "", attachments: [a], key: key)
        }
        #expect(store.transcript(for: conversation).last?.delivery == .notDelivered(.invalid("attachment_file_missing")))
        #expect(await source.uploadCalls.isEmpty)
    }

    /// The preview uploads with the image, travels on the part, and is the
    /// `.preview` variant; a part without one throws `no_preview`.
    @Test func previewUploadsWithTheImageAndFetchesAsAVariant() async throws {
        let (store, source) = try await started()
        let photo = try await store.prepareAttachment(data: try makeJPEG(width: 2000, height: 1500, orientation: 1),
                                                      typeIdentifier: UTType.jpeg.identifier)
        let meta = try #require(photo.ref.preview)
        try await store.send(conversation: conversation, text: "", attachments: [photo], key: IdempotencyKey("attach-preview"))
        await waitUntil { store.log.isEmpty }
        #expect(try await source.snapshot(of: conversation, tail: 1).messages.last?.parts == [.attachment(photo.ref)])
        #expect(try await store.fetchAttachment(photo.ref, variant: .preview, in: conversation) == photo.previewURL)
        let here = AttachmentLocation(conversation: conversation)
        let fetched = try await source.fetch(photo.ref, at: here, variant: .preview)
        #expect(sha256Hex(try Data(contentsOf: fetched)) == meta.hash)

        let small = try await store.prepareAttachment(data: try makeJPEG(width: 30, height: 30, orientation: 1),
                                                      typeIdentifier: UTType.jpeg.identifier)
        try await store.send(conversation: conversation, text: "", attachments: [small], key: IdempotencyKey("attach-no-preview"))
        await #expect(throws: HomeRejection.invalid("no_preview")) {
            try await store.fetchAttachment(small.ref, variant: .preview, in: conversation)
        }
        await #expect(throws: HomeRejection.invalid("no_preview")) {
            try await source.fetch(small.ref, at: here, variant: .preview)
        }
    }

    /// The owner recorded the image without a preview first: the part
    /// carries none.
    @Test func existsWithNoPreviewSendsThePartWithoutAPreview() async throws {
        let (store, source) = try await started()
        let photo = try await store.prepareAttachment(data: try makeJPEG(width: 1600, height: 1200, orientation: 1),
                                                      typeIdentifier: UTType.jpeg.identifier)
        #expect(photo.ref.preview != nil)
        var first = photo.ref
        first.preview = nil
        _ = try await source.upload(AttachmentUpload(conversation: conversation, fileURL: photo.fileURL, ref: first))
        try await store.send(conversation: conversation, text: "", attachments: [photo], key: IdempotencyKey("attach-exists-no-preview"))
        await waitUntil { store.log.isEmpty }
        #expect(try await source.snapshot(of: conversation, tail: 1).messages.last?.parts == [.attachment(first)])
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
        let url = try await other.fetchAttachment(b.ref, variant: .original, in: conversation)
        #expect(try Data(contentsOf: url) == Data("second".utf8))
        #expect(await source.fetchLocations.last == AttachmentLocation(conversation: conversation, message: message.id, partIndex: 1))
        await #expect(throws: HomeRejection.invalid("attachment_not_loaded")) {
            try await other.fetchAttachment(AttachmentRef(hash: "nowhere", name: "x", mimeType: "text/plain", byteCount: 1),
                                            variant: .original, in: conversation)
        }
    }

    /// The part goes out with the owner's mime spelling and without a
    /// size or duration the owner would refuse (a zero width from AV, a
    /// duration past 24 hours).
    @Test func sendCanonicalizesTheMimeTypeAndDropsOutOfRangeMediaFacts() async throws {
        let (store, source) = try await started()
        let photo = try await store.prepareAttachment(data: try makeJPEG(width: 8, height: 4, orientation: 1),
                                                      typeIdentifier: UTType.jpeg.identifier)
        var ref = photo.ref
        ref.mimeType = "image/JPG"
        ref.width = 0
        ref.height = 200_000
        ref.durationMs = 90_000_000
        let odd = LocalAttachment(ref: ref, fileURL: photo.fileURL)
        try await store.send(conversation: conversation, text: "", attachments: [odd], key: IdempotencyKey("attach-canonical"))
        var expected = photo.ref
        expected.width = nil
        expected.height = nil
        #expect(try await source.snapshot(of: conversation, tail: 1).messages.last?.parts == [.attachment(expected)])
    }

    /// The same bytes in two conversations: the fetch names the part in the
    /// conversation the row belongs to.
    @Test func fetchNamesThePartInTheRowsConversation() async throws {
        let (store, source) = try await started()
        let (a, _) = try await twoAttachments(store)
        let aziz = ConversationID("conv_aziz")
        await store.open(aziz)
        try await store.send(conversation: conversation, text: "", attachments: [a], key: IdempotencyKey("attach-two-a"))
        try await store.send(conversation: aziz, text: "", attachments: [a], key: IdempotencyKey("attach-two-b"))

        let other = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory())
        other.start()
        await waitUntil { other.isOnline && !other.rows.isEmpty }
        await other.open(conversation)
        await other.open(aziz)
        await waitUntil {
            other.transcript(for: self.conversation).last?.key == IdempotencyKey("attach-two-a")
                && other.transcript(for: aziz).last?.key == IdempotencyKey("attach-two-b")
        }
        for target in [aziz, conversation, aziz, conversation] {
            _ = try await other.fetchAttachment(a.ref, variant: .original, in: target)
            #expect(await source.fetchLocations.last?.conversation == target)
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
