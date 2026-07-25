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
        let paths = deduplicatedPaths(candidatePaths(in: normalized(input)))
        let attachments = paths.compactMap { path -> AttachmentPayload? in
            guard shouldPreview(path: path, toolName: toolName) else {
                return nil
            }
            let metadata = TranscriptImageMetadataProbe.metadata(hostPath: path, base64EncodedData: nil)
            let displayName = imageDisplayName(for: path)
            return AttachmentPayload(
                kind: "image",
                summary: displayName ?? "Image attachment",
                displayName: displayName,
                hostPath: path,
                mimeType: imageMIMEType(for: path),
                byteCount: metadata.byteCount,
                width: metadata.width,
                height: metadata.height,
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

    private func candidatePaths(in value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .string(let string):
            return string.hasPrefix("/") || string.hasPrefix("file://") ? [filePath(from: string)] : []
        case .array(let values):
            return values.flatMap { candidatePaths(in: normalized($0)) }
        case .object(let object):
            var paths: [String] = []
            for key in Self.pathKeys {
                if let path = object[key]?.string {
                    paths.append(filePath(from: path))
                }
            }
            for key in Self.nestedPathContainerKeys {
                paths.append(contentsOf: candidatePaths(in: normalized(object[key])))
            }
            return paths
        case .null, .bool, .number:
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

    private func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
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
}
