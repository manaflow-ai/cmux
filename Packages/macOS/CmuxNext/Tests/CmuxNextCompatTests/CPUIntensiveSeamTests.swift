@testable import CmuxNextCompat
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The size-gated seams for long CPU work (``BlockingKind/cpuIntensive``): above its gate each
/// seam on the main thread records one site at its caller's line; at or below the gate, or off the main thread (a
/// named queue, the pool, the `.cpu` lane), none records. Each test binds its own table
/// (``BlockingViolationTable/scoped``). Sites are compared by kind, location, count and context: their wall time
/// is the real clock's.
@Suite(.serialized)
struct CPUIntensiveSeamTests {
    /// The name the debug log and the hang reports use never changes.
    @Test func theKindKeepsItsName() {
        #expect(BlockingKind.cpuIntensive.rawValue == "cpu-intensive")
    }

    /// The gates: JSON 64 KiB, images 256 KiB of decoded pixels, compression 64 KiB uncompressed (a decompression
    /// without its expected size counts 8 times its input), regex 32 Ki UTF-16 units.
    @Test func theGatesAreTheDesignedSizes() {
        #expect(BlockingKind.cpuIntensiveJSONBytes == 65_536)
        #expect(BlockingKind.cpuIntensiveImagePixelBytes == 262_144)
        #expect(BlockingKind.cpuIntensiveCompressionBytes == 65_536)
        #expect(BlockingKind.cpuIntensiveCompressionRatio == 8)
        #expect(BlockingKind.cpuIntensiveRegexUTF16 == 32_768)
    }

    /// A decompression counts its expected size when given (at least the input), else 8 times its input, and
    /// saturates instead of overflowing.
    @Test func theDecompressionGateCountsTheOutput() {
        #expect(Data.decompressedBytes(compressed: 10, expected: nil) == 80)
        #expect(Data.decompressedBytes(compressed: 10, expected: 1_000) == 1_000)
        #expect(Data.decompressedBytes(compressed: 10, expected: 5) == 10)
        #expect(Data.decompressedBytes(compressed: .max, expected: nil) == .max)
    }

    /// An image's gate size is its header's width by height at 4 bytes a pixel (no pixel decoded), or the encoded
    /// size when that is larger.
    @Test nonisolated func theImageGateCountsDecodedPixels() throws {
        let png = try CPUFixture.png(side: CPUFixture.flatSide, flat: true)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(decodedImageBytes(source, at: 0, encoded: png.count) == CPUFixture.flatSide * CPUFixture.flatSide * 4)
        #expect(decodedImageBytes(source, at: 0, encoded: .max) == .max)
    }

    /// Each seam returns what the plain call returns, above and below its gate (off the main thread, so the large
    /// calls record nothing in the process's table).
    @Test nonisolated func theSeamsReturnThePlainCallsResults() throws {
        for large in [false, true] {
            let inputs = try CPUSeamInputs(large: large)
            let plain = try JSONDecoder().decode([String].self, from: inputs.json)
            #expect(try JSONDecoder().blockingDecode([String].self, from: inputs.json) == plain)
            #expect(try JSONSerialization.blockingJSONObject(with: inputs.json) as? [String] == plain)
            let listed = try PropertyListDecoder().decode([String].self, from: inputs.plist)
            #expect(try PropertyListDecoder().blockingDecode([String].self, from: inputs.plist) == listed)
            #expect(try PropertyListSerialization.blockingPropertyList(from: inputs.plist) as? [String] == listed)
            let expanded = try inputs.bytes.blockingCompress(using: .lzfse)
                .blockingDecompress(using: .lzfse, expectedSize: inputs.bytes.count)
            #expect(expanded == inputs.bytes)
            #expect(try inputs.bytes.blockingCompress(using: .lzfse).blockingDecompress(using: .lzfse) == inputs.bytes)
            let pairs = inputs.text.utf16.count / 2
            #expect(inputs.regex.blockingRegexMatches(in: inputs.text).count == pairs)
            #expect(inputs.regex.blockingRegexMatches(in: inputs.text, range: NSRange(location: 0, length: 4)).count == 2)
            #expect(inputs.regex.blockingRegexFirstMatch(in: inputs.text)?.range == NSRange(location: 0, length: 2))
            #expect(inputs.regex.blockingRegexNumberOfMatches(in: inputs.text) == pairs)
            #expect(inputs.regex.blockingRegexReplacingMatches(in: "xaby", withTemplate: "-") == "x-y")
            let side = large ? CPUFixture.largeSide : CPUFixture.smallSide
            let image = blockingImageDecode(inputs.png)
            #expect(image?.width == side)
            #expect(image?.height == side)
            let thumbnail = blockingImageThumbnail(inputs.png, options: CPUFixture.thumbnailOptions)
            #expect(thumbnail.map { max($0.width, $0.height) } == min(side, CPUFixture.thumbnailSide))
            let encoded = try #require(blockingImageEncode(inputs.image, type: UTType.png.identifier as CFString))
            #expect(blockingImageDecode(encoded)?.width == side)
        }
        #expect(blockingImageDecode(Data("not an image".utf8)) == nil)
        #expect(blockingImageThumbnail(Data("not an image".utf8), options: CPUFixture.thumbnailOptions) == nil)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The design's acceptance: a 100 KiB decode on the main thread is one site at its caller's line.
    @MainActor @Test func aHundredKibibyteDecodeOnTheMainThreadRecordsOneSite() async throws {
        let table = BlockingViolationTable(mode: .record)
        let json = CPUFixture.json(bytes: 100 * 1024)
        let expected = try BlockingViolationTable.$scoped.withValue(table) {
            var calls = CPUSeamCalls()
            try calls.seam(.cpuIntensive) { _ = try JSONDecoder().blockingDecode([String].self, from: json) }
            return calls.expected
        }
        await table.flush()

        #expect(expected.count == 1)
        #expect(CPUSeamCalls.observed(table) == expected)
    }

    /// The design's acceptance: the same decode of 1 KiB on the main thread is below the gate, no site.
    @MainActor @Test func aOneKibibyteDecodeOnTheMainThreadRecordsNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let json = CPUFixture.json(bytes: 1024)
        try BlockingViolationTable.$scoped.withValue(table) {
            _ = try JSONDecoder().blockingDecode([String].self, from: json)
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// Every seam above its gate on the main thread records one site at its caller's line.
    @MainActor @Test func eachSeamAboveItsGateOnTheMainThreadRecordsOneSite() async throws {
        let table = BlockingViolationTable(mode: .record)
        let inputs = try CPUSeamInputs(large: true)
        let expected = try BlockingViolationTable.$scoped.withValue(table) { try callEachCPUSeam(inputs) }
        await table.flush()

        #expect(expected.count == CPUSeamInputs.seamCount)
        #expect(Set(expected.map(\.location)).count == expected.count)
        #expect(CPUSeamCalls.observed(table) == expected)
    }

    /// Every seam at or below its gate on the main thread records nothing.
    @MainActor @Test func eachSeamBelowItsGateOnTheMainThreadRecordsNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let inputs = try CPUSeamInputs(large: false)
        let called = try BlockingViolationTable.$scoped.withValue(table) { try callEachCPUSeam(inputs).count }
        await table.flush()

        #expect(called == CPUSeamInputs.seamCount)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The design's finding: a screenshot-like PNG, far below 256 KiB encoded but many megabytes of pixels, decoded
    /// or scaled on the main thread is a site each time.
    @MainActor @Test func aSmallPNGOfManyPixelsOnTheMainThreadRecordsASite() async throws {
        let table = BlockingViolationTable(mode: .record)
        let png = try CPUFixture.png(side: CPUFixture.flatSide, flat: true)
        #expect(png.count < BlockingKind.cpuIntensiveImagePixelBytes)
        let expected = BlockingViolationTable.$scoped.withValue(table) {
            var calls = CPUSeamCalls()
            calls.seam(.cpuIntensive) { _ = blockingImageDecode(png) }
            calls.seam(.cpuIntensive) { _ = blockingImageThumbnail(png, options: CPUFixture.thumbnailOptions) }
            return calls.expected
        }
        await table.flush()

        #expect(expected.count == 2)
        #expect(CPUSeamCalls.observed(table) == expected)
    }

    /// A small compressed blob that expands past the gate on the main thread is a site: by its expected size when
    /// the caller passes it, and by 8 times its input otherwise. The same blob with a small expected size is not.
    @MainActor @Test func aSmallBlobThatExpandsPastTheGateOnTheMainThreadRecordsASite() async throws {
        let table = BlockingViolationTable(mode: .record)
        let text = Data(repeating: 0x61, count: 1024 * 1024)
        let blob = try (text as NSData).compressed(using: .lzfse) as Data
        let noise = try (CPUFixture.noise(bytes: 10 * 1024) as NSData).compressed(using: .lzfse) as Data
        #expect(blob.count * BlockingKind.cpuIntensiveCompressionRatio <= BlockingKind.cpuIntensiveCompressionBytes)
        #expect(noise.count < BlockingKind.cpuIntensiveCompressionBytes)
        let expected = try BlockingViolationTable.$scoped.withValue(table) {
            var calls = CPUSeamCalls()
            try calls.seam(.cpuIntensive) { _ = try blob.blockingDecompress(using: .lzfse, expectedSize: text.count) }
            try calls.seam(.cpuIntensive) { _ = try noise.blockingDecompress(using: .lzfse) }
            _ = try blob.blockingDecompress(using: .lzfse, expectedSize: 1024)
            return calls.expected
        }
        await table.flush()

        #expect(expected.count == 2)
        #expect(CPUSeamCalls.observed(table) == expected)
    }

    /// The gate is exclusive: an input of exactly the limit is not a site, one unit more is.
    @MainActor @Test func theGateCountsOnlyInputsLargerThanTheLimit() async {
        let table = BlockingViolationTable(mode: .record)
        let limit = BlockingKind.cpuIntensiveJSONBytes
        let expected = BlockingViolationTable.$scoped.withValue(table) {
            cpuIntensiveCall(size: limit, limit: limit) {}
            var calls = CPUSeamCalls()
            calls.seam(.cpuIntensive) { cpuIntensiveCall(size: limit + 1, limit: limit) {} }
            return calls.expected
        }
        await table.flush()

        #expect(CPUSeamCalls.observed(table) == expected)
    }

    /// A reviewed allowance covers long CPU work on the main thread as it covers a blocking call.
    @MainActor @Test func anAllowanceCoversALargeDecode() async throws {
        let table = BlockingViolationTable(mode: .record)
        let json = CPUFixture.json(bytes: 100 * 1024)
        try BlockingViolationTable.$scoped.withValue(table) {
            try allowBlocking(BlockingAllowance(reviewed: "test")) {
                _ = try JSONDecoder().blockingDecode([String].self, from: json)
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The design's acceptance: above their gates, the seams off the main thread record nothing, on a named
    /// serial queue (dedicated), on the pool (a detached task) and in a `.cpu` lane item, where long CPU work
    /// belongs. A file check beside them in each run records its pool or wrong-lane site, so the table and the
    /// context did see the run.
    @MainActor @Test func theSeamsOffTheMainThreadRecordNothing() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let onNamedQueue = try await callEachCPUSeamOnNamedQueue(table)
        let onPool = try await Task.detached { try callEachCPUSeamWithAFileCheck(table) }.value
        let onCPULane = try await Task.detached {
            try BlockingContext.runAsCPULane { try callEachCPUSeamWithAFileCheck(table) }
        }.value
        await table.flush()

        #expect(!onNamedQueue.onMain && !onPool.onMain && !onCPULane.onMain)
        #expect([onNamedQueue.called, onPool.called, onCPULane.called] == Array(repeating: CPUSeamInputs.seamCount, count: 3))
        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.fileIO, .wrongLane])
        #expect(Set(sites.map(\.context)) == [.pool, .cpuLane])
        #expect(Set(sites.map(\.location)) == [onPool.fileCheck])
    }
    #endif

    #if DEBUG
    /// Trap mode (`CMUX_BLOCKING_TRAP=1`) stops a Debug build at a large decode on the main thread, as at a
    /// blocking call.
    @Test func aLargeDecodeOnTheMainThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run {
                    _ = try? JSONDecoder().blockingDecode([String].self, from: CPUFixture.json(bytes: 100 * 1024))
                }
            }
        }
    }

    /// Below the gate trap mode does not stop it.
    @Test func aSmallDecodeOnTheMainThreadDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run {
                    _ = try? JSONDecoder().blockingDecode([String].self, from: CPUFixture.json(bytes: 1024))
                }
            }
        }
    }
    #endif
}

/// The inputs of ``callEachCPUSeam(_:)``: each above its seam's gate when `large`, each well below it otherwise.
private nonisolated struct CPUSeamInputs {
    /// How many seam calls ``callEachCPUSeam(_:)`` makes.
    static let seamCount = 14

    let json: Data
    let plist: Data
    let png: Data
    /// ``png`` decoded, the input of the encode seam.
    let image: CGImage
    let bytes: Data
    let compressed: Data
    let text: String
    let regex: NSRegularExpression

    init(large: Bool) throws {
        json = CPUFixture.json(bytes: large ? 100 * 1024 : 1024)
        plist = try CPUFixture.plist(bytes: large ? 100 * 1024 : 1024)
        png = try CPUFixture.png(side: large ? CPUFixture.largeSide : CPUFixture.smallSide)
        image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        bytes = CPUFixture.noise(bytes: large ? 100 * 1024 : 1024)
        // Noise does not compress, so the compressed input is above the gate too.
        compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
        text = String(repeating: "ab", count: large ? 20 * 1024 : 512)
        regex = try NSRegularExpression(pattern: "ab")
        let side = large ? CPUFixture.largeSide : CPUFixture.smallSide
        let sizes = [json.count, plist.count, side * side * 4, bytes.count,
                     compressed.count * BlockingKind.cpuIntensiveCompressionRatio, text.utf16.count]
        let gates = [BlockingKind.cpuIntensiveJSONBytes, BlockingKind.cpuIntensiveJSONBytes,
                     BlockingKind.cpuIntensiveImagePixelBytes, BlockingKind.cpuIntensiveCompressionBytes,
                     BlockingKind.cpuIntensiveCompressionBytes, BlockingKind.cpuIntensiveRegexUTF16]
        precondition(zip(sizes, gates).allSatisfy { large ? $0 > $1 : $0 * 4 <= $1 }, "\(sizes) against \(gates)")
    }
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Calls every CPU seam once on the caller's thread and returns the site each call records on the main thread
/// when its input is above the gate (its kind and this file's line of the call).
private nonisolated func callEachCPUSeam(_ inputs: CPUSeamInputs) throws -> [CPUSeamCalls.Site] {
    var calls = CPUSeamCalls()
    try calls.seam(.cpuIntensive) { _ = try JSONDecoder().blockingDecode([String].self, from: inputs.json) }
    try calls.seam(.cpuIntensive) { _ = try PropertyListDecoder().blockingDecode([String].self, from: inputs.plist) }
    try calls.seam(.cpuIntensive) { _ = try JSONSerialization.blockingJSONObject(with: inputs.json) }
    try calls.seam(.cpuIntensive) { _ = try PropertyListSerialization.blockingPropertyList(from: inputs.plist) }
    calls.seam(.cpuIntensive) { _ = blockingImageDecode(inputs.png) }
    calls.seam(.cpuIntensive) { _ = blockingImageThumbnail(inputs.png, options: CPUFixture.thumbnailOptions) }
    calls.seam(.cpuIntensive) { _ = blockingImageEncode(inputs.image, type: UTType.png.identifier as CFString) }
    try calls.seam(.cpuIntensive) { _ = try inputs.bytes.blockingCompress(using: .lzfse) }
    try calls.seam(.cpuIntensive) { _ = try inputs.compressed.blockingDecompress(using: .lzfse) }
    calls.seam(.cpuIntensive) { _ = inputs.regex.blockingRegexMatches(in: inputs.text) }
    calls.seam(.cpuIntensive) { _ = inputs.regex.blockingRegexFirstMatch(in: inputs.text) }
    calls.seam(.cpuIntensive) { _ = inputs.regex.blockingRegexNumberOfMatches(in: inputs.text) }
    calls.seam(.cpuIntensive) { _ = inputs.regex.blockingRegexReplacingMatches(in: inputs.text, withTemplate: "-") }
    let size = inputs.json.count
    calls.seam(.cpuIntensive) { cpuIntensiveCall(size: size, limit: BlockingKind.cpuIntensiveJSONBytes) {} }
    return calls.expected
}

/// One off-main run of ``callEachCPUSeam(_:)`` with large inputs.
private nonisolated struct OffMainRun: Sendable {
    /// Whether it ran on the main thread.
    var onMain: Bool
    /// How many seams it called.
    var called: Int
    /// The location of the file check made beside the seams (empty when the run made none).
    var fileCheck: String
}

/// Every CPU seam with large inputs, made here, on the calling thread with `table` bound, then one checked file
/// check, which records on a pool thread or in a `.cpu` lane item.
private nonisolated func callEachCPUSeamWithAFileCheck(_ table: BlockingViolationTable) throws -> OffMainRun {
    try BlockingViolationTable.$scoped.withValue(table) {
        let called = try callEachCPUSeam(CPUSeamInputs(large: true)).count
        let line: UInt = #line + 1
        _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
        return OffMainRun(onMain: pthread_main_np() != 0, called: called,
                          fileCheck: "CmuxNextCompatTests/CPUIntensiveSeamTests.swift:\(line)")
    }
}

/// Every CPU seam with large inputs, made there, on a named serial queue (a dedicated queue: blocking and long CPU
/// work are allowed there), with `table` bound there.
private nonisolated func callEachCPUSeamOnNamedQueue(_ table: BlockingViolationTable) async throws -> OffMainRun {
    let queue = DispatchQueue(label: "com.cmuxterm.tests.cpu-intensive-seams", qos: .userInitiated)
    return try await withCheckedThrowingContinuation { (done: CheckedContinuation<OffMainRun, any Error>) in
        queue.async {
            done.resume(with: Result {
                try BlockingViolationTable.$scoped.withValue(table) {
                    let called = try callEachCPUSeam(CPUSeamInputs(large: true)).count
                    return OffMainRun(onMain: pthread_main_np() != 0, called: called, fileCheck: "")
                }
            })
        }
    }
}

/// The sites a run of seam calls should record, each named where ``seam(_:fileID:line:_:)`` is called, which is
/// the seam's own line when the call is written on one line.
private nonisolated struct CPUSeamCalls {
    /// A site as these tests compare it: kind, location, count and context (the wall time is the real clock's).
    struct Site: Equatable {
        var kind: BlockingKind
        var location: String
        var count: Int
        var context: BlockingContext
    }

    private(set) var expected: [Site] = []

    mutating func seam(
        _ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ call: () throws -> Void
    ) rethrows {
        expected.append(Site(kind: kind, location: "\(fileID):\(line)", count: 1, context: .main))
        try call()
    }

    static func observed(_ table: BlockingViolationTable) -> [Site] {
        BlockingDetector(table: table).sites.map {
            Site(kind: $0.kind, location: $0.location, count: $0.count, context: $0.context)
        }
    }
}
#endif

/// Inputs of a chosen size, the same on every run.
private nonisolated enum CPUFixture {
    /// The side of the large test image: 400 by 400 pixels, 640,000 bytes decoded (noise: about 470 KiB of PNG).
    static let largeSide = 400
    /// The side of the small test image: 64 bytes decoded, well under 1 KiB of PNG.
    static let smallSide = 4
    /// The side of the flat test image: 1024 by 1024 pixels of one color, 4 MiB decoded from a few KiB of PNG, as
    /// a screenshot of text and flat colors compresses.
    static let flatSide = 1024
    /// The longest side ``thumbnailOptions`` asks for.
    static let thumbnailSide = 16
    /// Thumbnail options that always scale the full image down to ``thumbnailSide``.
    static var thumbnailOptions: [CFString: Any] {
        [kCGImageSourceThumbnailMaxPixelSize: thumbnailSide, kCGImageSourceCreateThumbnailFromImageAlways: true]
    }

    /// Strings of 100 characters, each different (a binary property list stores equal strings once).
    static func strings(bytes: Int) -> [String] {
        (0..<max(1, bytes / 101 + 1)).map { String(format: "%08d", $0) + String(repeating: "x", count: 92) }
    }

    /// A JSON array of strings of at least `bytes` bytes.
    static func json(bytes: Int) -> Data {
        Data(("[" + strings(bytes: bytes).map { "\"\($0)\"" }.joined(separator: ",") + "]").utf8)
    }

    /// A binary property list of an array of strings, of at least about `bytes` bytes.
    static func plist(bytes: Int) throws -> Data {
        try PropertyListEncoder().encode(strings(bytes: bytes))
    }

    /// `bytes` bytes that do not compress (xorshift from a fixed seed).
    static func noise(bytes: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return Data((0..<bytes).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
    }

    /// A `side` by `side` PNG of noise, or of one color when `flat`.
    static func png(side: Int, flat: Bool = false) throws -> Data {
        let pixels = flat ? Data(repeating: 0x80, count: side * side * 4) : noise(bytes: side * side * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}
