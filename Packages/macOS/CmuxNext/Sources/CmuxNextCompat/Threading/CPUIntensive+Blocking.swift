public import CoreGraphics
public import Foundation
public import ImageIO
#if DEBUG || CMUX_BLOCKING_CHECKS
// cpuIntensiveCall is inlinable and calls pthread_main_np(), so Darwin is a public import here.
public import Darwin
#endif

// The size-gated seams for long CPU work (``BlockingKind/cpuIntensive``). Chrome keeps this work off its UI thread:
// `AssertLongCPUWorkAllowed()` (base/threading/thread_restrictions.h) fails there, and large JSON and image decodes
// go to the data decoder service (services/data_decoder/public/cpp/data_decoder.h). Small work is cheap on any
// thread, so at or below its gate (by the size the work grows with: input bytes, decoded pixels, uncompressed bytes,
// searched text) a seam is the plain call; above it, on the main thread, it is a cpu-intensive site (timed like a
// blocking call). Off the main thread it is always the plain call: a lane, the pool and the
// `.cpu` lane are where this work belongs. Decode, compress or search a large input there and apply the result on
// main. threading-inventory.py `--rule cpu-intensive` lists the raw calls that run on the main thread (MQ-18).

/// Runs `body`, CPU work over `size` units of input, as a checked ``BlockingKind/cpuIntensive`` call: in builds with
/// the detector (Debug, bench, and Nightly to come), `body` on the main thread with `size` above `limit` records a
/// site at the caller's line and adds its wall time there (``blockingCall(_:fileID:line:_:)``'s main-thread path,
/// so ``allowBlocking(_:_:)`` and trap mode apply the same way). At or below `limit`, or off the main thread, and
/// in Release, it is `body` alone. The seams below call it; call it directly for other CPU work whose cost grows
/// with one input's size.
///
/// In every build, while a trace records the `task` category, the call is one `task.blocking_call` interval of kind
/// ``BlockingKind/cpuIntensive`` at its site, whatever its size and thread, through ``BlockingTraceHook`` as
/// ``blockingCall(_:fileID:line:_:)`` writes its own (plans/cmux-next/trace.md "Blocking calls and lane jobs").
///
/// Off the main thread it is the trace hook's one acquiring load and one `pthread_main_np()` call: `size` is read
/// only on the main thread (an image seam reads its header for it), and never in Release.
///
/// ```swift
/// let layout = cpuIntensiveCall(size: text.utf16.count, limit: 32 * 1024) { Layout(text) }
/// ```
///
/// - Parameters:
///   - size: The work's size, in the units `limit` counts.
///   - limit: The largest size that may run on the main thread without a site.
///   - fileID: The calling code's `#fileID` (a seam passes its own caller's).
///   - line: The calling code's `#line`.
///   - body: The CPU work.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@inlinable @inline(__always)
public func cpuIntensiveCall<Result, Failure: Error>(
    size: @autoclosure () -> Int, limit: Int, fileID: StaticString = #fileID, line: UInt = #line,
    _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    guard let sink = BlockingTraceHook.recordingSink else {
        return try checkedCPUIntensiveCall(size: size, limit: limit, fileID: fileID, line: line, body)
    }
    return try sink.interval(.cpuIntensive, fileID: fileID, line: line) { () throws(Failure) -> Result in
        try checkedCPUIntensiveCall(size: size, limit: limit, fileID: fileID, line: line, body)
    }
}

/// ``cpuIntensiveCall(size:limit:fileID:line:_:)`` without its trace interval: the detector's size gate, check and
/// timing around `body` (Debug and bench-checks builds), or `body` alone (Release).
@inlinable @inline(__always)
func checkedCPUIntensiveCall<Result, Failure: Error>(
    size: () -> Int, limit: Int, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    guard pthread_main_np() != 0, size() > limit else { return try body() }
    return try BlockingViolationTable.mainThreadBlockingCall(.cpuIntensive, fileID: fileID, line: line, body)
    #else
    return try body()
    #endif
}

extension JSONDecoder {
    /// Decodes a value, like `decode(_:from:)`, as a checked CPU call (``cpuIntensiveCall(size:limit:fileID:line:_:)``):
    /// on the main thread, `data` larger than ``BlockingKind/cpuIntensiveJSONBytes`` is a site.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The JSON bytes.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The decoded value.
    /// - Throws: What `decode(_:from:)` throws.
    @inlinable
    public func blockingDecode<T: Decodable>(
        _ type: T.Type, from data: Data, fileID: StaticString = #fileID, line: UInt = #line
    ) throws -> T {
        try cpuIntensiveCall(size: data.count, limit: BlockingKind.cpuIntensiveJSONBytes, fileID: fileID, line: line) {
            try decode(type, from: data)
        }
    }
}

extension PropertyListDecoder {
    /// Decodes a value, like `decode(_:from:)`, as a checked CPU call: on the main thread, `data` larger than
    /// ``BlockingKind/cpuIntensiveJSONBytes`` is a site.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The property list bytes.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The decoded value.
    /// - Throws: What `decode(_:from:)` throws.
    @inlinable
    public func blockingDecode<T: Decodable>(
        _ type: T.Type, from data: Data, fileID: StaticString = #fileID, line: UInt = #line
    ) throws -> T {
        try cpuIntensiveCall(size: data.count, limit: BlockingKind.cpuIntensiveJSONBytes, fileID: fileID, line: line) {
            try decode(type, from: data)
        }
    }
}

extension JSONSerialization {
    /// Parses JSON, like `jsonObject(with:options:)`, as a checked CPU call: on the main thread, `data` larger than
    /// ``BlockingKind/cpuIntensiveJSONBytes`` is a site.
    ///
    /// - Parameters:
    ///   - data: The JSON bytes.
    ///   - options: Foundation's reading options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The parsed object.
    /// - Throws: What `jsonObject(with:options:)` throws.
    @inlinable
    public static func blockingJSONObject(
        with data: Data, options: ReadingOptions = [], fileID: StaticString = #fileID, line: UInt = #line
    ) throws -> Any {
        try cpuIntensiveCall(size: data.count, limit: BlockingKind.cpuIntensiveJSONBytes, fileID: fileID, line: line) {
            try jsonObject(with: data, options: options)
        }
    }
}

extension PropertyListSerialization {
    /// Parses a property list, like `propertyList(from:options:format:)`, as a checked CPU call: on the main thread,
    /// `data` larger than ``BlockingKind/cpuIntensiveJSONBytes`` is a site.
    ///
    /// - Parameters:
    ///   - data: The property list bytes (XML, binary or OpenStep).
    ///   - options: Foundation's mutability options.
    ///   - format: Receives the format `data` was in, when not nil.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The parsed object.
    /// - Throws: What `propertyList(from:options:format:)` throws.
    @inlinable
    public static func blockingPropertyList(
        from data: Data, options: ReadOptions = [], format: UnsafeMutablePointer<PropertyListFormat>? = nil,
        fileID: StaticString = #fileID, line: UInt = #line
    ) throws -> Any {
        try cpuIntensiveCall(size: data.count, limit: BlockingKind.cpuIntensiveJSONBytes, fileID: fileID, line: line) {
            // SAFETY: forwards the caller's `format` pointer unchanged, only for the call; the caller's own `unsafe`
            // states why it is valid for it.
            try unsafe propertyList(from: data, options: options, format: format)
        }
    }
}

/// The bytes the image at `index` of `source` decodes to, 4 per pixel, from its header (no pixel is decoded), or
/// `encoded` when that is larger or the header names no size.
///
/// - Parameters:
///   - source: The image source.
///   - index: Which image of the source.
///   - encoded: The encoded image's size in bytes.
/// - Returns: The larger of the decoded and the encoded size, `Int.max` when the product overflows.
@usableFromInline
func decodedImageBytes(_ source: CGImageSource, at index: Int, encoded: Int) -> Int {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return encoded }
    let pixels = width.multipliedReportingOverflow(by: height)
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
    return pixels.overflow || bytes.overflow ? .max : max(encoded, bytes.partialValue)
}

/// Decodes one image of encoded image data (PNG, JPEG, HEIC...) to its pixels, as a checked CPU call: on the main
/// thread, an image that decodes to more than ``BlockingKind/cpuIntensiveImagePixelBytes`` (its header's width by
/// height, 4 bytes a pixel) is a site, however small `data` is.
///
/// The pixels are decoded here (`kCGImageSourceShouldCacheImmediately`), not where the image is first drawn, so the
/// work happens on the calling thread. For an `NSImage`, `NSBitmapImageRep` or `CIImage`, wrap the result with
/// `NSImage(cgImage:size:)`, `NSBitmapImageRep(cgImage:)` or `CIImage(cgImage:)`: `NSImage(data:)` leaves the
/// decode to its first draw, on the main thread. Read a file first with
/// ``Foundation/Data/init(blockingContentsOf:options:fileID:line:)``.
///
/// - Parameters:
///   - data: The encoded image.
///   - index: Which image of the source to decode.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The decoded image, or nil when `data` holds no image at `index`.
@inlinable
public func blockingImageDecode(
    _ data: Data, at index: Int = 0, fileID: StaticString = #fileID, line: UInt = #line
) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return cpuIntensiveCall(
        size: decodedImageBytes(source, at: index, encoded: data.count),
        limit: BlockingKind.cpuIntensiveImagePixelBytes,
        fileID: fileID, line: line
    ) { () -> CGImage? in
        let decodeNow = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, index, decodeNow)
    }
}

/// Makes a thumbnail of one image of encoded image data, like `CGImageSourceCreateThumbnailAtIndex`, as a checked
/// CPU call gated like ``blockingImageDecode(_:at:fileID:line:)``, by the full image's decoded bytes (the thumbnail
/// decodes the source to scale it).
///
/// - Parameters:
///   - data: The encoded image.
///   - index: Which image of the source to scale.
///   - options: ImageIO's thumbnail options (`kCGImageSourceThumbnailMaxPixelSize`,
///     `kCGImageSourceCreateThumbnailFromImageAlways`, ...).
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The thumbnail, or nil when `data` holds no image at `index`.
@inlinable
public func blockingImageThumbnail(
    _ data: Data, at index: Int = 0, options: [CFString: Any], fileID: StaticString = #fileID, line: UInt = #line
) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return cpuIntensiveCall(
        size: decodedImageBytes(source, at: index, encoded: data.count),
        limit: BlockingKind.cpuIntensiveImagePixelBytes,
        fileID: fileID, line: line
    ) { () -> CGImage? in
        CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}

/// Encodes `image` in memory as `type` (`UTType.png.identifier`, JPEG, HEIC...), like a `CGImageDestination` over
/// `NSMutableData` and its `CGImageDestinationFinalize`, as a checked CPU call gated like
/// ``blockingImageDecode(_:at:fileID:line:)``: on the main thread, an image of more than
/// ``BlockingKind/cpuIntensiveImagePixelBytes`` (width by height, 4 bytes a pixel) is a site. It writes no file, so
/// it is CPU work for the `.cpu` lane, where a file seam (``blockingImageDestinationFinalize(_:fileID:line:)``)
/// records a wrong-lane site. Chrome encodes in memory on its thread pool the same way
/// (chrome/browser/ui/thumbnails/thumbnail_image.cc, `ThumbnailImage::CompressBitmap`).
///
/// ```swift
/// let png = blockingImageEncode(frame, type: UTType.png.identifier as CFString)
/// ```
///
/// - Parameters:
///   - image: The image.
///   - type: The uniform type identifier of the encoding.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The encoded bytes, or nil when ImageIO cannot encode `image` as `type`.
@inlinable
public func blockingImageEncode(
    _ image: CGImage, type: CFString, fileID: StaticString = #fileID, line: UInt = #line
) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else { return nil }
    return cpuIntensiveCall(
        size: image.width * image.height * 4, limit: BlockingKind.cpuIntensiveImagePixelBytes, fileID: fileID, line: line
    ) { () -> Data? in
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

extension Data {
    /// Compresses the bytes, like `NSData.compressed(using:)`, as a checked CPU call: on the main thread, more than
    /// ``BlockingKind/cpuIntensiveCompressionBytes`` bytes is a site.
    ///
    /// - Parameters:
    ///   - algorithm: The compression algorithm.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The compressed bytes.
    /// - Throws: What `NSData.compressed(using:)` throws.
    @inlinable
    public func blockingCompress(
        using algorithm: NSData.CompressionAlgorithm, fileID: StaticString = #fileID, line: UInt = #line
    ) throws -> Data {
        try cpuIntensiveCall(size: count, limit: BlockingKind.cpuIntensiveCompressionBytes, fileID: fileID, line: line) {
            try (self as NSData).compressed(using: algorithm) as Data
        }
    }

    /// Decompresses the bytes, like `NSData.decompressed(using:)`, as a checked CPU call gated by its output: on the
    /// main thread, more than ``BlockingKind/cpuIntensiveCompressionBytes`` decompressed bytes is a site.
    ///
    /// The output's size is not known before the work, so the gate takes `expectedSize` when the caller knows it (a
    /// stored length, a header), else ``BlockingKind/cpuIntensiveCompressionRatio`` times the compressed bytes.
    ///
    /// - Parameters:
    ///   - algorithm: The algorithm the bytes were compressed with.
    ///   - expectedSize: The decompressed size in bytes, when the caller knows it.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The decompressed bytes.
    /// - Throws: What `NSData.decompressed(using:)` throws.
    @inlinable
    public func blockingDecompress(
        using algorithm: NSData.CompressionAlgorithm, expectedSize: Int? = nil,
        fileID: StaticString = #fileID, line: UInt = #line
    ) throws -> Data {
        try cpuIntensiveCall(
            size: Self.decompressedBytes(compressed: count, expected: expectedSize),
            limit: BlockingKind.cpuIntensiveCompressionBytes, fileID: fileID, line: line
        ) {
            try (self as NSData).decompressed(using: algorithm) as Data
        }
    }

    /// The decompressed size the gate counts: `expected` (at least `compressed`), or
    /// ``BlockingKind/cpuIntensiveCompressionRatio`` times `compressed`, `Int.max` when that overflows.
    ///
    /// - Parameters:
    ///   - compressed: The compressed size in bytes.
    ///   - expected: The decompressed size in bytes, when the caller knows it.
    /// - Returns: The size in bytes.
    @usableFromInline
    static func decompressedBytes(compressed: Int, expected: Int?) -> Int {
        if let expected { return Swift.max(compressed, expected) }
        let estimate = compressed.multipliedReportingOverflow(by: BlockingKind.cpuIntensiveCompressionRatio)
        return estimate.overflow ? .max : estimate.partialValue
    }
}

extension NSRegularExpression {
    /// Runs `search` over `range` of `string` (all of it when nil) as a checked CPU call gated by
    /// ``BlockingKind/cpuIntensiveRegexUTF16`` UTF-16 code units: the regular-expression seams' shared gate.
    @inlinable
    func checkedSearch<Result>(
        of string: String, range: NSRange?, fileID: StaticString, line: UInt, _ search: (NSRange) -> Result
    ) -> Result {
        let searched = range ?? NSRange(location: 0, length: string.utf16.count)
        return cpuIntensiveCall(
            size: searched.length, limit: BlockingKind.cpuIntensiveRegexUTF16, fileID: fileID, line: line
        ) { search(searched) }
    }

    /// Finds every match, like `matches(in:options:range:)`, as a checked CPU call: on the main thread, a searched
    /// range longer than ``BlockingKind/cpuIntensiveRegexUTF16`` UTF-16 code units is a site.
    ///
    /// - Parameters:
    ///   - string: The text to search.
    ///   - options: Foundation's matching options.
    ///   - range: The UTF-16 range of `string` to search; nil searches all of it.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: What `matches(in:options:range:)` returns.
    @inlinable
    public func blockingRegexMatches(
        in string: String, options: MatchingOptions = [], range: NSRange? = nil,
        fileID: StaticString = #fileID, line: UInt = #line
    ) -> [NSTextCheckingResult] {
        checkedSearch(of: string, range: range, fileID: fileID, line: line) { searched in
            matches(in: string, options: options, range: searched)
        }
    }

    /// Finds the first match, like `firstMatch(in:options:range:)`, as a checked CPU call gated like
    /// ``blockingRegexMatches(in:options:range:fileID:line:)``.
    ///
    /// - Parameters:
    ///   - string: The text to search.
    ///   - options: Foundation's matching options.
    ///   - range: The UTF-16 range of `string` to search; nil searches all of it.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: What `firstMatch(in:options:range:)` returns.
    @inlinable
    public func blockingRegexFirstMatch(
        in string: String, options: MatchingOptions = [], range: NSRange? = nil,
        fileID: StaticString = #fileID, line: UInt = #line
    ) -> NSTextCheckingResult? {
        checkedSearch(of: string, range: range, fileID: fileID, line: line) { searched in
            firstMatch(in: string, options: options, range: searched)
        }
    }

    /// Counts the matches, like `numberOfMatches(in:options:range:)`, as a checked CPU call gated like
    /// ``blockingRegexMatches(in:options:range:fileID:line:)``.
    ///
    /// - Parameters:
    ///   - string: The text to search.
    ///   - options: Foundation's matching options.
    ///   - range: The UTF-16 range of `string` to search; nil searches all of it.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: What `numberOfMatches(in:options:range:)` returns.
    @inlinable
    public func blockingRegexNumberOfMatches(
        in string: String, options: MatchingOptions = [], range: NSRange? = nil,
        fileID: StaticString = #fileID, line: UInt = #line
    ) -> Int {
        checkedSearch(of: string, range: range, fileID: fileID, line: line) { searched in
            numberOfMatches(in: string, options: options, range: searched)
        }
    }

    /// Replaces the matches with a template, like `stringByReplacingMatches(in:options:range:withTemplate:)`, as a
    /// checked CPU call gated like ``blockingRegexMatches(in:options:range:fileID:line:)``.
    ///
    /// - Parameters:
    ///   - string: The text to search.
    ///   - options: Foundation's matching options.
    ///   - range: The UTF-16 range of `string` to search; nil searches all of it.
    ///   - template: The replacement template (`$1` names a capture group).
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: What `stringByReplacingMatches(in:options:range:withTemplate:)` returns.
    @inlinable
    public func blockingRegexReplacingMatches(
        in string: String, options: MatchingOptions = [], range: NSRange? = nil, withTemplate template: String,
        fileID: StaticString = #fileID, line: UInt = #line
    ) -> String {
        checkedSearch(of: string, range: range, fileID: fileID, line: line) { searched in
            stringByReplacingMatches(in: string, options: options, range: searched, withTemplate: template)
        }
    }
}
