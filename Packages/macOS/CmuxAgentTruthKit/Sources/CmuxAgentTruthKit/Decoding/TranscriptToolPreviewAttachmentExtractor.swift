import CmuxAgentReplica
import Foundation

/// Extracts lightweight inline preview metadata from tool inputs.
///
/// The transcript row should not wait for image bytes before reserving layout.
/// Tool inputs usually already carry the host path, and the TruthKit side can
/// cheaply stat local files while minting replica entries.
struct TranscriptToolPreviewAttachmentExtractor: Sendable {
    private let lineDecoder: JSONLineDecoder

    init(lineDecoder: JSONLineDecoder = JSONLineDecoder()) {
        self.lineDecoder = lineDecoder
    }

    func previewAttachments(
        toolName: String,
        input: JSONValue?,
        authorRole: String?
    ) -> [AttachmentPayload]? {
        let candidates = deduplicatedCandidates(candidateReferences(in: normalized(input)))
        let attachments = candidates.compactMap { candidate -> AttachmentPayload? in
            let path = candidate.hostPath
            guard shouldPreview(path: path, toolName: toolName) else {
                return nil
            }
            let metadata = TranscriptImageMetadataProbe.metadata(hostPath: path, base64EncodedData: nil)
            let displayName = candidate.displayName ?? imageDisplayName(for: path)
            return AttachmentPayload(
                kind: "image",
                summary: displayName ?? "Image attachment",
                displayName: displayName,
                hostPath: path,
                mimeType: candidate.mimeType ?? imageMIMEType(for: path),
                byteCount: candidate.byteCount ?? metadata.byteCount,
                width: candidate.width ?? metadata.width,
                height: candidate.height ?? metadata.height,
                aspectRatio: candidate.aspectRatio,
                authorRole: authorRole
            )
        }
        return attachments.isEmpty ? nil : attachments
    }

    private func normalized(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if let string = value.string {
            return lineDecoder.decode(string) ?? value
        }
        return value
    }

    private func candidateReferences(in value: JSONValue?) -> [PreviewAttachmentCandidate] {
        guard let value else { return [] }
        switch value {
        case .string(let string):
            return string.hasPrefix("/") || string.hasPrefix("file://")
                ? [PreviewAttachmentCandidate(hostPath: filePath(from: string))]
                : []
        case .array(let values):
            return values.flatMap { candidateReferences(in: normalized($0)) }
        case .object(let object):
            var candidates: [PreviewAttachmentCandidate] = []
            for key in Self.pathKeys {
                if let path = object[key]?.string {
                    candidates.append(previewCandidate(path: path, object: object))
                }
            }
            for key in Self.nestedPathContainerKeys {
                candidates.append(contentsOf: candidateReferences(in: normalized(object[key])))
            }
            return candidates
        case .null, .bool, .number:
            return []
        }
    }

    private func previewCandidate(
        path: String,
        object: [String: JSONValue]
    ) -> PreviewAttachmentCandidate {
        let metadataObjects = previewMetadataObjects(from: object)
        return PreviewAttachmentCandidate(
            hostPath: filePath(from: path),
            displayName: string(in: metadataObjects, keys: Self.displayNameKeys),
            mimeType: string(in: metadataObjects, keys: Self.mimeTypeKeys),
            byteCount: int(in: metadataObjects, keys: Self.byteCountKeys),
            width: int(in: metadataObjects, keys: Self.widthKeys),
            height: int(in: metadataObjects, keys: Self.heightKeys),
            aspectRatio: aspectRatio(in: metadataObjects)
        )
    }

    private func previewMetadataObjects(from object: [String: JSONValue]) -> [[String: JSONValue]] {
        var objects = [object]
        for key in Self.metadataContainerKeys {
            guard let value = normalized(object[key]) else { continue }
            objects.append(contentsOf: previewMetadataObjects(in: value))
        }
        return objects
    }

    private func previewMetadataObjects(in value: JSONValue) -> [[String: JSONValue]] {
        switch value {
        case .object(let object):
            return previewMetadataObjects(from: object)
        case .array(let values):
            return values.flatMap { previewMetadataObjects(in: normalized($0) ?? $0) }
        case .null, .bool, .number, .string:
            return []
        }
    }

    private func shouldPreview(path: String, toolName: String) -> Bool {
        guard isLocalFilePath(path) else {
            return false
        }
        if isImagePreviewTool(toolName) {
            return true
        }
        if imageMIMEType(for: path)?.hasPrefix("image/") == true {
            return true
        }
        return false
    }

    private func isLocalFilePath(_ path: String) -> Bool {
        if path.hasPrefix("/") {
            return true
        }
        guard let url = URL(string: path) else {
            return false
        }
        return url.isFileURL
    }

    private func isImagePreviewTool(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "view_image"
            || normalized == "open_image"
            || normalized == "screenshot"
            || normalized.contains("view_image")
            || normalized.contains("image_preview")
    }

    private func filePath(from value: String) -> String {
        guard let url = URL(string: value), url.isFileURL else {
            return value
        }
        return url.path
    }

    private func deduplicatedCandidates(
        _ candidates: [PreviewAttachmentCandidate]
    ) -> [PreviewAttachmentCandidate] {
        var indexesByPath: [String: Int] = [:]
        var deduplicated: [PreviewAttachmentCandidate] = []
        for candidate in candidates {
            let trimmedPath = candidate.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                continue
            }
            let trimmed = candidate.withHostPath(trimmedPath)
            if let existingIndex = indexesByPath[trimmedPath] {
                deduplicated[existingIndex] = deduplicated[existingIndex].merged(with: trimmed)
            } else {
                indexesByPath[trimmedPath] = deduplicated.count
                deduplicated.append(trimmed)
            }
        }
        return deduplicated
    }

    private func string(in objects: [[String: JSONValue]], keys: [String]) -> String? {
        for object in objects {
            for key in keys {
                if let value = object[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func int(in objects: [[String: JSONValue]], keys: [String]) -> Int? {
        for object in objects {
            for key in keys {
                if let value = object[key]?.int, value > 0 {
                    return value
                }
                if let string = object[key]?.string,
                   let value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)),
                   value > 0 {
                    return value
                }
            }
        }
        return nil
    }

    private func aspectRatio(in objects: [[String: JSONValue]]) -> Double? {
        for object in objects {
            for key in Self.aspectRatioKeys {
                guard let value = object[key] else {
                    continue
                }
                if let ratio = normalizedAspectRatio(value.number) {
                    return ratio
                }
                if let ratio = value.string.flatMap(aspectRatioValue) {
                    return ratio
                }
            }
        }
        return nil
    }

    private func aspectRatioValue(_ rawValue: String) -> Double? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(value).flatMap(normalizedAspectRatio) {
            return direct
        }
        let parts = value.split { $0 == ":" || $0 == "/" }.compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else {
            return nil
        }
        return normalizedAspectRatio(parts[0] / parts[1])
    }

    private func normalizedAspectRatio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 1_000 else {
            return nil
        }
        return value
    }

    private func imageDisplayName(for path: String) -> String? {
        let displayName = URL(fileURLWithPath: path).lastPathComponent
        return displayName.isEmpty ? nil : displayName
    }

    private func imageMIMEType(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "svg": "image/svg+xml"
        default: nil
        }
    }

    private struct PreviewAttachmentCandidate: Equatable, Sendable {
        let hostPath: String
        let displayName: String?
        let mimeType: String?
        let byteCount: Int?
        let width: Int?
        let height: Int?
        let aspectRatio: Double?

        init(
            hostPath: String,
            displayName: String? = nil,
            mimeType: String? = nil,
            byteCount: Int? = nil,
            width: Int? = nil,
            height: Int? = nil,
            aspectRatio: Double? = nil
        ) {
            self.hostPath = hostPath
            self.displayName = displayName
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.width = width
            self.height = height
            self.aspectRatio = aspectRatio
        }

        func withHostPath(_ hostPath: String) -> Self {
            PreviewAttachmentCandidate(
                hostPath: hostPath,
                displayName: displayName,
                mimeType: mimeType,
                byteCount: byteCount,
                width: width,
                height: height,
                aspectRatio: aspectRatio
            )
        }

        func merged(with other: Self) -> Self {
            PreviewAttachmentCandidate(
                hostPath: hostPath,
                displayName: displayName ?? other.displayName,
                mimeType: mimeType ?? other.mimeType,
                byteCount: byteCount ?? other.byteCount,
                width: width ?? other.width,
                height: height ?? other.height,
                aspectRatio: aspectRatio ?? other.aspectRatio
            )
        }
    }

    private static let displayNameKeys = [
        "display_name",
        "fileName",
        "file_name",
        "filename",
        "name",
    ]

    private static let mimeTypeKeys = [
        "contentType",
        "content_type",
        "mediaType",
        "media_type",
        "mime",
        "mimeType",
        "mime_type",
    ]

    private static let byteCountKeys = [
        "byteLength",
        "byte_length",
        "bytes",
        "byteCount",
        "byte_count",
        "contentLength",
        "content_length",
        "fileSize",
        "file_size",
        "size",
    ]

    private static let widthKeys = [
        "imageWidth",
        "image_width",
        "naturalWidth",
        "natural_width",
        "previewWidth",
        "preview_width",
        "pixelWidth",
        "pixel_width",
        "width",
        "w",
    ]

    private static let heightKeys = [
        "imageHeight",
        "image_height",
        "naturalHeight",
        "natural_height",
        "previewHeight",
        "preview_height",
        "pixelHeight",
        "pixel_height",
        "height",
        "h",
    ]

    private static let aspectRatioKeys = [
        "aspectRatio",
        "aspect_ratio",
        "previewAspectRatio",
        "preview_aspect_ratio",
        "ratio",
    ]

    private static let pathKeys = [
        "absolute_path",
        "file_path",
        "host_path",
        "image_path",
        "local_path",
        "path",
        "screenshot_path",
        "uri",
        "url",
    ]

    private static let nestedPathContainerKeys = [
        "attachment",
        "file",
        "image",
        "input_image",
        "source",
    ]

    private static let metadataContainerKeys = [
        "artifact",
        "attachment",
        "dimensions",
        "file",
        "image",
        "image_metadata",
        "metadata",
        "meta",
        "preview",
        "preview_metadata",
    ]
}
