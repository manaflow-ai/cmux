import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import CmuxHomeCore

// Regression tests for the second attachment review.

// MARK: Fixtures

/// Location found anywhere in a movie: asset or track metadata items, or a
/// timed metadata track.
struct MovieLocation: Equatable {
    var asset = false
    var track = false
    var timedTracks = 0
    var any: Bool { asset || track || timedTracks > 0 }
}

func isLocationItem(_ item: AVMetadataItem) -> Bool {
    guard let raw = item.identifier?.rawValue else { return item.commonKey == .commonKeyLocation }
    return raw.hasPrefix("mdta/com.apple.quicktime.location.") || raw == AVMetadataIdentifier.commonIdentifierLocation.rawValue
        || raw == AVMetadataIdentifier.quickTimeUserDataLocationISO6709.rawValue || item.commonKey == .commonKeyLocation
}

func movieLocation(_ url: URL) async throws -> MovieLocation {
    let asset = AVURLAsset(url: url)
    var found = MovieLocation()
    found.asset = try await asset.load(.metadata).contains(where: isLocationItem)
    for track in try await asset.load(.tracks) {
        if track.mediaType == .metadata { found.timedTracks += 1 }
        if try await track.load(.metadata).contains(where: isLocationItem) { found.track = true }
    }
    return found
}

/// A one-second silent AAC file (`.m4a`) carrying an ISO 6709 location.
func makeM4A(at url: URL, location: String) async throws {
    let plain = url.deletingLastPathComponent().appendingPathComponent("plain-\(UUID().uuidString).m4a")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    try {
        let file = try AVAudioFile(forWriting: plain, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        try file.write(from: buffer)
    }() // the file closes when it is released
    let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough))
    var items: [AVMetadataItem] = []
    for identifier in [AVMetadataIdentifier.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709] {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = location as NSString
        items.append(item)
    }
    session.metadata = items
    session.outputURL = url
    session.outputFileType = .m4a
    await session.export()
    #expect(session.status == .completed, "m4a export failed: \(String(describing: session.error))")
}

/// IPTC location keys an image may carry as text.
var iptcLocationKeys: [CFString] { [
    kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
    kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
    kCGImagePropertyIPTCContentLocationName, kCGImagePropertyIPTCContentLocationCode,
] }

/// True when the image holds a position or a place name anywhere: the GPS
/// dictionary, IPTC location text, or an XMP location tag.
func imageHasLocation(_ data: Data) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    for index in 0..<CGImageSourceGetCount(source) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if iptcLocationKeys.contains(where: { iptc[$0] != nil }) { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else { continue }
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            if (prefix == "exif" && name.hasPrefix("GPS")) || (prefix == "photoshop" && ["City", "State", "Country"].contains(name))
                || (prefix == "Iptc4xmpCore" && ["Location", "CountryCode"].contains(name))
                || (prefix == "Iptc4xmpExt" && ["LocationShown", "LocationCreated"].contains(name)) {
                found = true
            }
            return !found
        }
        if found { return true }
    }
    return false
}

func imageOrientation(_ data: Data) throws -> Int {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
}

private func opaqueImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// A JPEG whose only location is IPTC text (a city and a sub-location).
func makeJPEGWithIPTCLocation() throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    let iptc: [CFString: Any] = [kCGImagePropertyIPTCCity: "Cupertino", kCGImagePropertyIPTCSubLocation: "Apple Park",
                                 kCGImagePropertyIPTCCaptionAbstract: "keep me"]
    CGImageDestinationAddImage(destination, try opaqueImage(width: 40, height: 20),
                               [kCGImagePropertyIPTCDictionary: iptc, kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A JPEG whose location is XMP: GPS tags and place names in the packet.
func makeJPEGWithXMPLocation() throws -> Data {
    let packet = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/"
     xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     exif:GPSLatitude="37,20.094N" exif:GPSLongitude="122,0.54W" photoshop:City="Cupertino"
     Iptc4xmpCore:Location="Apple Park"/>
    </rdf:RDF></x:xmpmeta>
    """
    let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImageAndMetadata(destination, try opaqueImage(width: 30, height: 30), metadata, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A 1x1 lossless WebP (with an alpha channel) whose EXIF holds a GPS
/// position. ImageIO reads WebP but cannot write it, so the EXIF block is
/// taken from a JPEG and wrapped in RIFF chunks by hand.
func makeWebPWithLocation() throws -> Data {
    let jpeg = [UInt8](try makeJPEGWithLocation(width: 4, height: 4))
    var index = 2
    var tiff: [UInt8] = []
    while index + 4 < jpeg.count {
        let length = Int(jpeg[index + 2]) << 8 | Int(jpeg[index + 3])
        if jpeg[index + 1] == 0xE1, jpeg[(index + 4)..<(index + 10)].elementsEqual(Array("Exif\0\0".utf8)) {
            tiff = Array(jpeg[(index + 10)..<(index + 2 + length)])
            break
        }
        index += 2 + length
    }
    #expect(!tiff.isEmpty)
    func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xff) } }
    func chunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
        Array(tag.utf8) + le32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
    }
    let vp8l: [UInt8] = [0x2f, 0x00, 0x00, 0x00, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07]
    let vp8x: [UInt8] = [0x18, 0, 0, 0, 0, 0, 0, 0, 0, 0] // alpha + EXIF, 1x1 canvas
    let body = Array("WEBP".utf8) + chunk("VP8X", vp8x) + chunk("VP8L", vp8l) + chunk("EXIF", tiff)
    return Data(Array("RIFF".utf8) + le32(body.count) + body)
}

/// A `width` x `height` PNG whose left half is fully transparent.
func makeTransparentPNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// The smallest alpha value in the image (255 when it has no alpha).
func minimumAlpha(_ url: URL) throws -> UInt8 {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.min() ?? 255
}

// MARK: Preparation

@Suite(.timeLimit(.minutes(3))) struct AttachmentRoundTwoPreparationTests {
    /// Finding 2 (Lawrence's decision): an image with transparency gets no
    /// preview (a JPEG would turn the transparent areas black, and the
    /// owner keeps the first preview for good); readers load the original.
    /// The local thumbnail keeps the transparency (PNG).
    @MainActor @Test func transparentImagesGetNoPreviewAndKeepAlphaInTheLocalThumbnail() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let png = try makeTransparentPNG(width: 2400, height: 1200)
        let prepared = try await store.prepareAttachment(data: png, typeIdentifier: UTType.png.identifier)
        #expect(prepared.ref.mimeType == "image/png")
        #expect(prepared.ref.preview == nil)
        #expect(prepared.previewURL == nil)

        let thumb = try await store.fetchAttachment(prepared.ref, variant: .thumbnail(maxPixel: 200),
                                                    in: ConversationID("conv_austin"))
        let source = try #require(CGImageSourceCreateWithURL(thumb as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 200)
        #expect(try minimumAlpha(thumb) == 0)

        // An opaque image of the same size still gets its JPEG preview.
        let opaque = try await store.prepareAttachment(data: try makeJPEG(width: 2400, height: 1200, orientation: 1),
                                                       typeIdentifier: UTType.jpeg.identifier)
        #expect(opaque.ref.preview != nil)
    }

    /// Finding 3: location an M4A carries is removed like a video's.
    @MainActor @Test func audioLocationIsStrippedUnlessKept() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let audio = root.appendingPathComponent("memo.m4a")
        try await makeM4A(at: audio, location: "+37.3349-122.0090/")
        try #require(try await movieLocation(audio).any, "fixture must carry a location")

        let stripped = try await store.prepareAttachment(fileURL: audio)
        #expect(try await movieLocation(stripped.fileURL) == MovieLocation())
        #expect(stripped.ref.mimeType == "audio/mp4")
        #expect(stripped.ref.name == "memo.m4a")
        #expect(stripped.ref.hash == sha256Hex(try Data(contentsOf: stripped.fileURL)))
        let duration = try #require(stripped.ref.durationMs)
        #expect(abs(duration - 1000) <= 100)

        let pasted = try await store.prepareAttachment(data: try Data(contentsOf: audio), typeIdentifier: UTType.mpeg4Audio.identifier)
        #expect(try await movieLocation(pasted.fileURL) == MovieLocation())

        let kept = try await store.prepareAttachment(fileURL: audio, keepLocation: true)
        #expect(kept.ref.hash == sha256Hex(try Data(contentsOf: audio)))
    }

    /// Finding 3: track-level location items, a timed metadata track of
    /// positions, and a place name without coordinates are all removed.
    @MainActor @Test func movieTrackTimedAndNamedLocationsAreStripped() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))

        let tracked = root.appendingPathComponent("tracked.mov")
        try await makeMovie(at: tracked, width: 64, height: 32, trackLocation: "+37.3349-122.0090/")
        try #require(try await movieLocation(tracked).track, "fixture must carry a track location")
        let timed = root.appendingPathComponent("timed.mov")
        try await makeMovie(at: timed, width: 64, height: 32, timedLocation: "+37.3349-122.0090/")
        try #require(try await movieLocation(timed).timedTracks == 1, "fixture must carry a timed metadata track")
        let named = root.appendingPathComponent("named.mov")
        try await makeMovie(at: named, width: 64, height: 32, locationName: "Apple Park")
        try #require(try await movieLocation(named).asset, "fixture must carry a location name")

        for movie in [tracked, timed, named] {
            let stripped = try await store.prepareAttachment(fileURL: movie)
            #expect(try await movieLocation(stripped.fileURL) == MovieLocation(), "\(movie.lastPathComponent)")
            #expect(stripped.ref.hash == sha256Hex(try Data(contentsOf: stripped.fileURL)))
            #expect(stripped.ref.width == 32 && stripped.ref.height == 64) // the track transform stays
            #expect(stripped.ref.poster != nil)
            #expect(try await AVURLAsset(url: stripped.fileURL).loadTracks(withMediaType: .video).count == 1)
        }

        // keepLocation keeps the timed track (the bytes are untouched).
        let kept = try await store.prepareAttachment(fileURL: timed, keepLocation: true)
        #expect(kept.ref.hash == sha256Hex(try Data(contentsOf: timed)))
    }

    /// Finding 3: a photo whose location is IPTC text or XMP (no EXIF GPS
    /// dictionary) is stripped too; other metadata and orientation stay.
    @MainActor @Test func photoIPTCAndXMPLocationsAreStripped() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let iptc = try makeJPEGWithIPTCLocation()
        try #require(try imageHasLocation(iptc), "fixture must carry IPTC location")
        let xmp = try makeJPEGWithXMPLocation()
        try #require(try imageHasLocation(xmp), "fixture must carry XMP location")

        let cleanIPTC = try await store.prepareAttachment(data: iptc, typeIdentifier: UTType.jpeg.identifier)
        let iptcBytes = try Data(contentsOf: cleanIPTC.fileURL)
        #expect(try !imageHasLocation(iptcBytes))
        #expect(try imageOrientation(iptcBytes) == 6)
        #expect(cleanIPTC.ref.width == 20 && cleanIPTC.ref.height == 40)
        #expect(cleanIPTC.ref.hash == sha256Hex(iptcBytes))

        let file = root.appendingPathComponent("xmp.jpg")
        try xmp.write(to: file)
        let cleanXMP = try await store.prepareAttachment(fileURL: file)
        let xmpBytes = try Data(contentsOf: cleanXMP.fileURL)
        #expect(try !imageHasLocation(xmpBytes))
        #expect(cleanXMP.ref.name == "xmp.jpg")
        #expect(cleanXMP.ref.hash == sha256Hex(xmpBytes))

        let kept = try await store.prepareAttachment(data: iptc, typeIdentifier: UTType.jpeg.identifier, keepLocation: true)
        #expect(kept.ref.hash == sha256Hex(iptc))
    }

    /// Finding 4: ImageIO cannot write WebP, so a WebP with GPS is
    /// converted (PNG, since it has alpha) without its location instead of
    /// being refused.
    @MainActor @Test func aWebPWithLocationIsConvertedNotRefused() async throws {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        try #require(!writable.contains(UTType.webP.identifier), "this test needs a system that cannot write WebP")
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let webp = try makeWebPWithLocation()
        try #require(try imageHasLocation(webp), "fixture must carry GPS")

        let file = root.appendingPathComponent("sticker.webp")
        try webp.write(to: file)
        let converted = try await store.prepareAttachment(fileURL: file)
        let bytes = try Data(contentsOf: converted.fileURL)
        #expect(try !imageHasLocation(bytes))
        #expect(converted.ref.mimeType == "image/png")
        #expect(converted.ref.name == "sticker.png")
        #expect(converted.ref.hash == sha256Hex(bytes))
        #expect(converted.ref.width == 1 && converted.ref.height == 1)

        let pasted = try await store.prepareAttachment(data: webp, typeIdentifier: UTType.webP.identifier)
        #expect(try !imageHasLocation(try Data(contentsOf: pasted.fileURL)))
        #expect(pasted.ref.mimeType == "image/png")

        // Without location the WebP is sent as it is.
        let kept = try await store.prepareAttachment(data: webp, typeIdentifier: UTType.webP.identifier, keepLocation: true)
        #expect(kept.ref.mimeType == "image/webp")
        #expect(kept.ref.hash == sha256Hex(webp))
    }

    /// Finding 10: the owner trims names with JS `trim()`, which also
    /// removes U+FEFF; a name of only that character is blank.
    @Test func aNameOfOnlyAByteOrderMarkIsBlank() throws {
        for blank in ["\u{FEFF}", " \u{FEFF}\u{2003}", "\u{FEFF}\u{A0}"] {
            #expect(!HomeAttachmentPolicy.isValidName(blank))
            #expect(throws: HomeAttachmentError.invalidName(name: blank)) {
                try HomeAttachmentPolicy.check(mimeType: "text/plain", byteCount: 1, name: blank)
            }
            #expect(HomeAttachmentPolicy.sendableName(blank) == "attachment")
        }
        #expect(HomeAttachmentPolicy.isValidName("\u{FEFF}a.txt"))
    }

    /// Finding 5: a prune that read the cache before `prepare` reused a
    /// blob directory must not delete it afterwards. Just before the prune
    /// deletes the stale blob, the same bytes are attached again; that
    /// blob must still be there when both finish.
    @MainActor @Test func aPruneNeverDeletesABlobPrepareJustReturned() async throws {
        let root = try temporaryDirectory()
        let fm = FileManager.default
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let bytes = Data("attached again".utf8)
        let first = try await store.prepareAttachment(data: bytes, typeIdentifier: UTType.plainText.identifier)
        let reused = first.fileURL.deletingLastPathComponent()
        let now = Date()
        // A new store (a relaunch) that has not prepared it: the blob is stale.
        let relaunched = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: reused.path)

        let attached = OSAllocatedUnfairLock<LocalAttachment?>(initialState: nil)
        let started = OSAllocatedUnfairLock(initialState: false)
        relaunched.pruneWillDelete = { name in
            guard name == reused.lastPathComponent, !started.withLock({ $0 }) else { return }
            started.withLock { $0 = true }
            Task { @MainActor in
                let again = try? await relaunched.prepareAttachment(data: bytes, typeIdentifier: UTType.plainText.identifier)
                attached.withLock { $0 = again }
            }
            // Give the prepare every chance to finish before this delete
            // (it cannot while it correctly waits for the prune).
            for _ in 0..<100_000 where attached.withLock({ $0 }) == nil { await Task.yield() }
        }
        await relaunched.pruneBlobCache(now: now)
        try #require(started.withLock { $0 }, "the prune must have reached the stale blob")
        for _ in 0..<100_000 where attached.withLock({ $0 }) == nil { await Task.yield() }
        let again = try #require(attached.withLock { $0 })
        #expect(again.fileURL == first.fileURL)
        #expect(fm.fileExists(atPath: again.fileURL.path))
        #expect(try Data(contentsOf: again.fileURL) == bytes)
    }

    /// Finding 5: the cache is pruned again while the store runs (macOS
    /// never purges Caches), paced by the store's clock.
    @MainActor @Test func theCacheIsPrunedPeriodicallyWhileTheStoreRuns() async throws {
        let root = try temporaryDirectory()
        let fm = FileManager.default
        let clock = ManualClock()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root, clock: clock)
        store.start()
        defer { store.stop() }
        // The first pass ran and the next one waits on the clock.
        for _ in 0..<200_000 where clock.pendingSleepers == 0 { await Task.yield() }
        try #require(clock.pendingSleepers > 0, "the store must wait on its clock for the next prune")

        let stale = root.appendingPathComponent("stale", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: stale.path)
        clock.advance(by: HomeStore.blobCachePruneInterval)
        for _ in 0..<200_000 where fm.fileExists(atPath: stale.path) { await Task.yield() }
        #expect(!fm.fileExists(atPath: stale.path))
    }
}

// MARK: Sending

@MainActor
@Suite(.timeLimit(.minutes(3))) struct AttachmentRoundTwoSendTests {
    let conversation = ConversationID("conv_austin")

    func started(clock: ManualClock = ManualClock()) async throws -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory(), clock: clock)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: self.conversation).isEmpty }
        return (store, source)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<5_000 where !condition() { await Task.yield() }
    }

    func drainTasks() async {
        for _ in 0..<500 { await Task.yield() }
    }

    func text(_ value: String) -> HomeOp { .sendMessage(conversation: conversation, parts: [.text(value)]) }

    func committed(_ key: IdempotencyKey, in source: MockHomeSource) async throws -> Int {
        try await source.snapshot(of: conversation, tail: 20).messages.filter { $0.clientMessageID == key }.count
    }

    /// Finding 1: a send that never gets an answer while the socket stays
    /// up (resent once at once, still unanswered) is resent with backoff on
    /// the store's clock, then fails "Not Delivered" so the text queued
    /// behind it goes; retry resends it under the same key (the owner may
    /// have committed it), so it commits once.
    @Test func anUnansweredHeadBacksOffThenFailsAndTheQueueMoves() async throws {
        let clock = ManualClock()
        let (store, source) = try await started(clock: clock)
        let head = IdempotencyKey("stall-head")
        let next = IdempotencyKey("stall-next")
        await source.failNextSubmits(of: head, times: 1_000)
        let first = Task { try await store.perform(text("one"), key: head) }
        await drainTasks()
        let second = Task { try await store.perform(text("two"), key: next) }
        await drainTasks()
        #expect(store.log.entries.first { $0.intent.key == next }?.isQueued == true)
        #expect(try await committed(next, in: source) == 0)
        await #expect(throws: HomeSendState.pendingResend) { try await first.value }

        var steps = 0
        while try await committed(next, in: source) == 0, steps < 20 {
            clock.advance(by: .seconds(600))
            await drainTasks()
            steps += 1
        }
        try #require(try await committed(next, in: source) == 1, "the queued text must go once the head fails")
        _ = try await second.value
        let failed = try #require(store.transcript(for: conversation).first { $0.key == head })
        #expect(failed.delivery == .notDelivered(.indeterminate))
        #expect(try await committed(head, in: source) == 0)

        await source.failNextSubmits(of: head, times: 0)
        try await store.retry(head)
        await waitUntil { store.log.isEmpty }
        #expect(try await committed(head, in: source) == 1)
        #expect(store.transcript(for: conversation).contains { $0.key == head && $0.delivery == .committed })
    }

    /// Finding 1: a send queued behind an upload can be cancelled.
    @Test func cancelSendDropsAQueuedSend() async throws {
        let (store, source) = try await started()
        let a = try await store.prepareAttachment(data: Data("queued".utf8), typeIdentifier: UTType.plainText.identifier)
        await source.setUploadsPaused(true)
        let photoKey = IdempotencyKey("queue-photo")
        let textKey = IdempotencyKey("queue-text")
        let photo = Task { try await store.send(conversation: conversation, text: "", attachments: [a], key: photoKey) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        let queued = Task { try await store.perform(text("never"), key: textKey) }
        await waitUntil { store.log.entries.first { $0.intent.key == textKey }?.isQueued == true }

        try #require(store.cancelSend(textKey))
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(!store.transcript(for: conversation).contains { $0.key == textKey })
        await source.setUploadsPaused(false)
        try await photo.value
        await waitUntil { store.log.isEmpty }
        #expect(try await committed(photoKey, in: source) == 1)
        #expect(try await committed(textKey, in: source) == 0)
    }

    /// Finding 6: after the automatic resend for `unknown_attachment`, the
    /// send keeps its place: a text queued behind it still commits after it.
    @Test func theUnknownAttachmentResendKeepsItsQueuePosition() async throws {
        let (store, source) = try await started()
        let a = try await store.prepareAttachment(data: Data("swept".utf8), typeIdentifier: UTType.plainText.identifier)
        await source.forgetBlobBeforeNextSubmits(a.ref.hash)
        await source.setUploadsPaused(true)
        let photo = Task {
            try await store.send(conversation: conversation, text: "", attachments: [a], key: IdempotencyKey("swept-photo"))
        }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        let textKey = IdempotencyKey("swept-text")
        let after = Task { try await store.perform(text("after"), key: textKey) }
        await waitUntil { store.log.entries.first { $0.intent.key == textKey }?.isQueued == true }
        await source.setUploadsPaused(false)
        try await photo.value
        _ = try await after.value
        await waitUntil { store.log.isEmpty }
        let page = try await source.snapshot(of: conversation, tail: 5)
        let photoSeq = try #require(page.messages.first { $0.parts == [.attachment(a.ref)] }?.seq)
        let textSeq = try #require(page.messages.first { $0.clientMessageID == textKey }?.seq)
        #expect(photoSeq < textSeq)
    }

    /// Finding 7: the owner kept another device's poster, so the pending
    /// row's part names a poster hash this client does not have; the row
    /// is not committed, so the source cannot fetch it either. The local
    /// poster frame of the same video is shown.
    @Test func aPendingRowShowsTheLocalPosterAfterAdoption() async throws {
        let (store, source) = try await started()
        let root = try temporaryDirectory()
        let movie = root.appendingPathComponent("clip.mov")
        try await makeMovie(at: movie, width: 64, height: 32)
        let video = try await store.prepareAttachment(fileURL: movie)
        let localPoster = try #require(video.posterURL)
        let otherData = try makeJPEG(width: 16, height: 32, orientation: 1)
        let otherURL = root.appendingPathComponent("other-poster.jpg")
        try otherData.write(to: otherURL)
        var first = video.ref
        first.poster = AttachmentPoster(hash: sha256Hex(otherData), mimeType: "image/jpeg", byteCount: otherData.count)
        _ = try await source.upload(AttachmentUpload(conversation: conversation, fileURL: video.fileURL, ref: first,
                                                     posterURL: otherURL))

        let key = IdempotencyKey("adopted-pending")
        await source.failNextSubmits(of: key, times: 1_000)
        let send = Task { try await store.send(conversation: conversation, text: "", attachments: [video], key: key) }
        await waitUntil { store.log.entries.first { $0.intent.key == key }?.state == .unconfirmed }
        let row = try #require(store.transcript(for: conversation).first { $0.key == key })
        #expect(row.delivery == .sending)
        guard case .attachment(let pending)? = row.parts.first else { Issue.record("no attachment part"); return }
        #expect(pending.poster == first.poster)
        let poster = try await store.fetchAttachment(pending, variant: .poster, in: conversation)
        #expect(poster == localPoster)
        send.cancel()
        store.stop()
    }

    /// Finding 8: `stop()` (sign-out) cancels uploads in flight.
    @Test func stopCancelsUploadsInFlight() async throws {
        let (store, source) = try await started()
        let a = try await store.prepareAttachment(data: Data("signed out".utf8), typeIdentifier: UTType.plainText.identifier)
        await source.setUploadsPaused(true)
        let send = Task { try await store.send(conversation: conversation, text: "", attachments: [a], key: IdempotencyKey("stop-upload")) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        store.stop()
        await drainTasks()
        await source.setUploadsPaused(false)
        _ = try? await send.value
        await drainTasks()
        #expect(await !source.hasBlob(a.ref.hash))
    }

    /// Finding 9: an upload resumed on reconnect that the owner refuses
    /// reaches the host through `onRefusal` (nobody awaits that pass).
    @Test func aRefusedResumedUploadReachesOnRefusal() async throws {
        let (store, source) = try await started()
        var refused: [(HomeIntent, HomeRejection)] = []
        store.onRefusal = { refused.append(($0, $1)) }
        let a = try await store.prepareAttachment(data: Data("resumed".utf8), typeIdentifier: UTType.plainText.identifier)
        await source.setUploadsPaused(true)
        let key = IdempotencyKey("resumed-refused")
        let send = Task { try await store.send(conversation: conversation, text: "", attachments: [a], key: key) }
        await waitUntil { store.transcript(for: self.conversation).last?.attachmentProgress[a.ref.hash] == 0.5 }
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        await source.setUploadsPaused(false)
        await #expect(throws: HomeSendState.pendingResend) { try await send.value }
        #expect(refused.isEmpty)

        await source.failNextUpload(hash: a.ref.hash, with: .invalid("attachment_upload_failed"))
        await source.setOnline(true)
        await waitUntil { !refused.isEmpty }
        #expect(refused.map(\.0.key) == [key])
        #expect(refused.map(\.1) == [.invalid("attachment_upload_failed")])
        #expect(store.transcript(for: conversation).last?.delivery == .notDelivered(.invalid("attachment_upload_failed")))
    }
}
