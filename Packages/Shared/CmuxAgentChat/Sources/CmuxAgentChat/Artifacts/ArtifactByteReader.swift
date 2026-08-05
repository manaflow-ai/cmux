import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads already-authorized artifact bytes and metadata from the local filesystem.
///
/// Authorization is intentionally outside this type. Callers must scope-check the
/// requested path before invoking these methods.
public struct ArtifactByteReader: Sendable {
    /// Maximum immediate children returned by one directory-list request.
    public static let maximumDirectoryEntryCount = 500
    private static let utf8SniffByteCount = 8 * 1024

    /// Filesystem/decoder failures surfaced by artifact RPC handlers.
    public enum Error: Swift.Error, Sendable {
        /// The scoped path no longer exists or cannot be statted.
        case fileNotFound
        /// The operation does not apply to this media type.
        case unsupportedMedia
    }

    /// Creates a byte reader.
    public init() {}

    /// Reads metadata for an already-authorized path.
    public func stat(path: String) throws -> ChatArtifactStat {
        let attributes = try attributes(path: path)
        return stat(path: path, attributes: attributes)
    }

    /// Reads one clamped byte chunk for an already-authorized file path.
    public func fetch(path: String, offset: Int64, length: Int) throws -> ChatArtifactChunk {
        let attributes = try attributes(path: path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw Error.unsupportedMedia
        }
        let opened = try openVerifiedRegularFile(path: path)
        let handle = opened.handle
        defer { try? handle.close() }
        let totalSize = opened.size
        let clampedOffset = min(max(offset, 0), totalSize)
        try handle.seek(toOffset: UInt64(clampedOffset))
        let data = try handle.read(upToCount: max(0, length)) ?? Data()
        let endOffset = clampedOffset + Int64(data.count)
        return ChatArtifactChunk(
            data: data,
            offset: clampedOffset,
            totalSize: totalSize,
            eof: endOffset >= totalSize
        )
    }

    private func stat(
        path: String,
        attributes: [FileAttributeKey: Any]
    ) -> ChatArtifactStat {
        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let kind = kind(
            path: path,
            isDirectory: isDirectory,
            isRegularFile: fileType == .typeRegular
        )
        let imageDimensions = imageDimensions(path: path, kind: kind)
        return ChatArtifactStat(
            exists: true,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt,
            kind: kind,
            mimeType: mimeType(path: path, isDirectory: isDirectory),
            pixelWidth: imageDimensions?.width,
            pixelHeight: imageDimensions?.height
        )
    }

    private func imageDimensions(path: String, kind: ChatArtifactKind) -> (width: Int, height: Int)? {
        guard kind == .image else { return nil }
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = Self.intProperty(properties[kCGImagePropertyPixelWidth]),
           let height = Self.intProperty(properties[kCGImagePropertyPixelHeight]),
           width > 0,
           height > 0 {
            return (width, height)
        }
        return svgDimensions(path: path)
    }

    private static func intProperty(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let int as Int:
            return int
        default:
            return nil
        }
    }

    private func svgDimensions(path: String) -> (width: Int, height: Int)? {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "svg",
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 128 * 1_024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<svg", options: [.caseInsensitive]) != nil else {
            return nil
        }
        if let width = svgLength(named: "width", in: text),
           let height = svgLength(named: "height", in: text),
           width > 0,
           height > 0 {
            return (width, height)
        }
        guard let viewBox = svgAttribute(named: "viewBox", in: text) else {
            return nil
        }
        let numbers = viewBox
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .compactMap { Double($0) }
        guard numbers.count >= 4,
              numbers[2] > 0,
              numbers[3] > 0 else {
            return nil
        }
        return (roundedPixelDimension(numbers[2]), roundedPixelDimension(numbers[3]))
    }

    private func svgLength(named name: String, in text: String) -> Int? {
        guard let rawValue = svgAttribute(named: name, in: text),
              let number = leadingNumber(rawValue),
              number > 0 else {
            return nil
        }
        return roundedPixelDimension(number)
    }

    private func svgAttribute(named name: String, in text: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b\#(escapedName)\s*=\s*["']([^"']+)["']"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private func leadingNumber(_ value: String) -> Double? {
        let pattern = #"^[ \t\r\n]*([+-]?(?:\d+(?:\.\d+)?|\.\d+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let matchRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Double(value[matchRange])
    }

    private func roundedPixelDimension(_ value: Double) -> Int {
        max(1, Int(value.rounded()))
    }

    /// Generates a JPEG thumbnail for an already-authorized image path.
    public func thumbnail(path: String, maxDimension: Int) throws -> ChatArtifactThumbnail {
        let opened = try openVerifiedRegularFile(path: path)
        try? opened.handle.close()
        guard kind(path: path, isDirectory: false) == .image else {
            throw Error.unsupportedMedia
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Error.unsupportedMedia
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw Error.unsupportedMedia
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.unsupportedMedia
        }
        return ChatArtifactThumbnail(
            data: destinationData as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Lists up to ``maximumDirectoryEntryCount`` immediate children for an
    /// already-authorized directory.
    ///
    /// One readdir pass collects child names; per-child filesystem metadata is
    /// read only for the capped entries that the listing actually returns.
    public func list(path: String) throws -> ChatArtifactDirectoryListing {
        let stat = try stat(path: path)
        guard stat.isDirectory else { throw Error.fileNotFound }
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        let sortedNames = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        let listed = try sortedNames
            .prefix(Self.maximumDirectoryEntryCount)
            .map { name -> ChatArtifactDirectoryEntry in
                let entry = directoryURL.appendingPathComponent(name)
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values.isDirectory ?? false
                return ChatArtifactDirectoryEntry(
                    name: name,
                    isDirectory: isDirectory,
                    size: Int64(values.fileSize ?? 0),
                    kind: kind(path: entry.path, isDirectory: isDirectory)
                )
            }
        return ChatArtifactDirectoryListing(
            entries: listed,
            isTruncated: names.count > Self.maximumDirectoryEntryCount
        )
    }

    /// Infers preview category from directory status, extension, and a verified regular-file UTF-8 sniff.
    public func kind(path: String, isDirectory: Bool) -> ChatArtifactKind {
        return kind(
            path: path,
            isDirectory: isDirectory,
            isRegularFile: nil
        )
    }

    private func kind(
        path: String,
        isDirectory: Bool,
        isRegularFile: Bool?
    ) -> ChatArtifactKind {
        if isDirectory { return .directory }
        if isRegularFile == false { return .binary }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        guard let type, !type.isDynamic else {
            let verifiedRegularFile: Bool
            if let isRegularFile {
                verifiedRegularFile = isRegularFile
            } else {
                let attributes = try? attributes(path: path)
                verifiedRegularFile = (attributes?[.type] as? FileAttributeType) == .typeRegular
            }
            guard verifiedRegularFile else { return .binary }
            return isUTF8Text(path: path) ? .text : .binary
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    private func isUTF8Text(path: String) -> Bool {
        guard let opened = try? openVerifiedRegularFile(path: path) else {
            return false
        }
        let handle = opened.handle
        defer { try? handle.close() }
        let bytes: Data
        do {
            bytes = try handle.read(upToCount: Self.utf8SniffByteCount + 1) ?? Data()
        } catch {
            return false
        }
        let sample = Data(bytes.prefix(Self.utf8SniffByteCount))
        if String(data: sample, encoding: .utf8) != nil {
            return true
        }
        guard bytes.count > Self.utf8SniffByteCount else {
            return false
        }
        return hasValidUTF8PrefixEndingInPartialScalar(sample)
    }

    private func hasValidUTF8PrefixEndingInPartialScalar(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return false }
        let earliestCandidate = max(0, bytes.count - 4)
        for start in stride(from: bytes.count - 1, through: earliestCandidate, by: -1) {
            guard let expectedLength = utf8ScalarLength(leadingByte: bytes[start]) else {
                continue
            }
            let actualLength = bytes.count - start
            guard actualLength < expectedLength,
                  utf8PartialScalarBytesAreValid(Array(bytes[start...])) else {
                continue
            }
            let prefix = Data(bytes[..<start])
            return String(data: prefix, encoding: .utf8) != nil
        }
        return false
    }

    /// Opens `path` without blocking and validates the opened descriptor as a regular file.
    func openVerifiedRegularFile(path: String) throws -> (handle: FileHandle, size: Int64) {
        // Set close-on-exec atomically at open; fcntl afterward cannot close the fork race.
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.fileNotFound }

        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw Error.unsupportedMedia
        }

        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }

        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            max(Int64(metadata.st_size), 0)
        )
    }

    private func utf8ScalarLength(leadingByte: UInt8) -> Int? {
        switch leadingByte {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }

    private func utf8PartialScalarBytesAreValid(_ bytes: [UInt8]) -> Bool {
        guard let leadingByte = bytes.first else { return false }
        for byte in bytes.dropFirst() where byte & 0xC0 != 0x80 {
            return false
        }
        guard bytes.count > 1 else { return true }
        let firstContinuation = bytes[1]
        switch leadingByte {
        case 0xE0:
            return firstContinuation >= 0xA0
        case 0xED:
            return firstContinuation <= 0x9F
        case 0xF0:
            return firstContinuation >= 0x90
        case 0xF4:
            return firstContinuation <= 0x8F
        default:
            return true
        }
    }

    private func attributes(path: String) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw Error.fileNotFound
        }
    }

    private func mimeType(path: String, isDirectory: Bool) -> String? {
        guard !isDirectory,
              let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }
}
