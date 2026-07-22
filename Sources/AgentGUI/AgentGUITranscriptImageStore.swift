import CmuxAgentReplica
import CmuxAgentTruthKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Validates and materializes embedded transcript images outside the main actor.
actor AgentGUITranscriptImageStore {
    static let shared = AgentGUITranscriptImageStore()

    struct Limits: Sendable {
        let maximumEncodedCharacterCount: Int
        let maximumDecodedByteCount: Int
        let maximumPixelCount: Int
        let maximumPixelDimension: Int
        let maximumCacheByteCount: Int
        let maximumCacheFileCount: Int
        let maximumCacheAge: TimeInterval

        static let `default` = Limits(
            maximumEncodedCharacterCount: ((8 * 1_024 * 1_024 + 2) / 3) * 4,
            maximumDecodedByteCount: 8 * 1_024 * 1_024,
            maximumPixelCount: 100_000_000,
            maximumPixelDimension: 32_768,
            maximumCacheByteCount: 256 * 1_024 * 1_024,
            maximumCacheFileCount: 2_048,
            maximumCacheAge: 30 * 24 * 60 * 60
        )
    }

    struct MaterializedImage: Sendable {
        let path: String
        let mimeType: String
        let byteCount: Int
        let width: Int
        let height: Int
    }

    struct ReferencedImage: Sendable {
        let entrySeq: EntrySeq
        let path: String
        let mimeType: String?
    }

    private struct CachedFile {
        let url: URL
        let byteCount: Int
        let modifiedAt: Date
    }

    private let rootURL: URL
    private let limits: Limits

    init(
        rootURL: URL? = nil,
        limits: Limits = .default
    ) {
        self.rootURL = rootURL ?? Self.defaultRootURL
        self.limits = limits
    }

    func materialize(
        _ images: [TranscriptEmbeddedImage]
    ) -> [EntrySeq: MaterializedImage] {
        guard !images.isEmpty, prepareRootDirectory() else { return [:] }
        var materializedBySequence: [EntrySeq: MaterializedImage] = [:]
        for image in images where materializedBySequence[image.entrySeq] == nil {
            guard let materialized = materialize(image) else { continue }
            materializedBySequence[image.entrySeq] = materialized
        }
        pruneCache(protecting: Set(materializedBySequence.values.map(\.path)))
        return materializedBySequence
    }

    /// Reads local-image metadata without copying the original file. This lets
    /// path-backed Codex images reserve their real aspect ratio immediately.
    func inspect(
        _ images: [ReferencedImage]
    ) -> [EntrySeq: MaterializedImage] {
        var inspectedBySequence: [EntrySeq: MaterializedImage] = [:]
        for image in images where inspectedBySequence[image.entrySeq] == nil {
            guard image.path.hasPrefix("/"),
                  image.path.utf8.count <= 4_096 else { continue }
            let url = URL(fileURLWithPath: image.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let typeIdentifier = CGImageSourceGetType(source) as String?,
                  let type = UTType(typeIdentifier),
                  type.conforms(to: .image),
                  declaredMIMEType(image.mimeType, matches: type),
                  let mimeType = type.preferredMIMEType,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = integer(properties[kCGImagePropertyPixelWidth]),
                  let height = integer(properties[kCGImagePropertyPixelHeight]),
                  width > 0,
                  height > 0,
                  width <= limits.maximumPixelDimension,
                  height <= limits.maximumPixelDimension,
                  width <= limits.maximumPixelCount / height,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let byteCount = (attributes[.size] as? NSNumber)?.intValue,
                  byteCount >= 0 else { continue }
            inspectedBySequence[image.entrySeq] = MaterializedImage(
                path: url.path,
                mimeType: mimeType,
                byteCount: byteCount,
                width: width,
                height: height
            )
        }
        return inspectedBySequence
    }

    private func materialize(_ image: TranscriptEmbeddedImage) -> MaterializedImage? {
        let encodedData = image.base64EncodedData
        guard !encodedData.isEmpty,
              encodedData.utf8.count <= limits.maximumEncodedCharacterCount,
              estimatedDecodedByteCount(encodedData) <= limits.maximumDecodedByteCount,
              let data = Data(base64Encoded: encodedData),
              !data.isEmpty,
              data.count <= limits.maximumDecodedByteCount,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = integer(properties[kCGImagePropertyPixelWidth]),
              let height = integer(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0,
              width <= limits.maximumPixelDimension,
              height <= limits.maximumPixelDimension,
              width <= limits.maximumPixelCount / height,
              declaredMIMEType(image.mimeType, matches: type),
              let mimeType = type.preferredMIMEType,
              let filenameExtension = type.preferredFilenameExtension else { return nil }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = rootURL.appendingPathComponent(
            "\(digest).\(filenameExtension.lowercased())",
            isDirectory: false
        )
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: destination.path
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        } else {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )
        }
        return MaterializedImage(
            path: destination.path,
            mimeType: mimeType,
            byteCount: data.count,
            width: width,
            height: height
        )
    }

    private func prepareRootDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: rootURL.path
            )
            return true
        } catch {
            return false
        }
    }

    private func pruneCache(protecting protectedPaths: Set<String>) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        var files: [CachedFile] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let file = CachedFile(
                url: url,
                byteCount: max(0, values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
            if !protectedPaths.contains(url.path),
               now.timeIntervalSince(file.modifiedAt) > limits.maximumCacheAge {
                try? FileManager.default.removeItem(at: url)
            } else {
                files.append(file)
            }
        }
        var totalBytes = files.reduce(0) { $0 + $1.byteCount }
        var fileCount = files.count
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard totalBytes > limits.maximumCacheByteCount
                    || fileCount > limits.maximumCacheFileCount else { break }
            guard !protectedPaths.contains(file.url.path) else { continue }
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            totalBytes -= file.byteCount
            fileCount -= 1
        }
    }

    private func estimatedDecodedByteCount(_ encoded: String) -> Int {
        let count = encoded.utf8.count
        guard count > 0 else { return 0 }
        let padding = encoded.suffix(2).filter { $0 == "=" }.count
        return max(0, ((count + 3) / 4) * 3 - padding)
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private func declaredMIMEType(_ declared: String?, matches actualType: UTType) -> Bool {
        guard let declared = declared?.lowercased(), !declared.isEmpty else { return true }
        guard declared.hasPrefix("image/"), let actual = actualType.preferredMIMEType?.lowercased() else {
            return false
        }
        if declared == actual { return true }
        return Set([declared, actual]) == Set(["image/jpg", "image/jpeg"])
    }

    private static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("AgentTranscriptImages", isDirectory: true)
    }
}
