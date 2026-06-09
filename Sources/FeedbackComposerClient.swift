import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

enum FeedbackComposerSettings {
    static let storedEmailKey = "sidebarHelpFeedbackEmail"
    static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    static let defaultEndpoint = "https://cmux.com/api/feedback"
    static let foundersEmail = "founders@manaflow.com"
    static let maxMessageLength = 4_000
    static let maxAttachmentCount = 10
    // Keep the multipart body below Vercel's 4.5 MB request limit.
    static let maxTotalAttachmentBytes = 4 * 1_024 * 1_024
    static let targetTotalAttachmentUploadBytes = 3_500_000

    static func endpointURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: defaultEndpoint)
    }
}

struct FeedbackComposerAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64
    let mimeType: String

    var standardizedPath: String {
        url.standardizedFileURL.path
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    init(url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .nameKey,
        ])
        guard resourceValues.isRegularFile != false else {
            throw CocoaError(.fileReadUnknown)
        }

        self.url = url
        self.fileName = resourceValues.name ?? url.lastPathComponent
        self.fileSize = Int64(resourceValues.fileSize ?? 0)
        self.mimeType = resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream"
    }
}

private struct PreparedFeedbackComposerAttachment {
    let fileName: String
    let mimeType: String
    let data: Data
}

private struct FeedbackComposerAppMetadata {
    let appVersion: String
    let appBuild: String
    let appCommit: String
    let bundleIdentifier: String
    let osVersion: String
    let localeIdentifier: String
    let hardwareModel: String
    let chip: String
    let memoryGB: String
    let architecture: String
    let displayInfo: String

    static var current: FeedbackComposerAppMetadata {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let commit = (infoDictionary["CMUXCommit"] as? String).flatMap { value in
            value.isEmpty ? nil : value
        } ?? env["CMUX_COMMIT"]

        return FeedbackComposerAppMetadata(
            appVersion: infoDictionary["CFBundleShortVersionString"] as? String ?? "",
            appBuild: infoDictionary["CFBundleVersion"] as? String ?? "",
            appCommit: commit ?? "",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hardwareModel: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            memoryGB: formatMemoryGB(),
            architecture: currentArchitecture(),
            displayInfo: currentDisplayInfo()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMemoryGB() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return "\(Int(gb)) GB"
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func currentDisplayInfo() -> String {
        let screens = NSScreen.screens
        let descriptions = screens.map { screen -> String in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return "\(Int(frame.width))x\(Int(frame.height)) @\(Int(scale))x"
        }
        let count = screens.count
        let prefix = "\(count) display\(count == 1 ? "" : "s")"
        return "\(prefix), \(descriptions.joined(separator: "; "))"
    }
}

enum FeedbackComposerSubmissionError: Error {
    case invalidEndpoint
    case invalidResponse
    case rejected(statusCode: Int)
    case attachmentReadFailed
    case attachmentPreparationFailed
    case transport(URLError)
}

enum FeedbackComposerClient {
    private static let passthroughAttachmentMIMETypes: Set<String> = [
        "image/gif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/png",
        "image/tiff",
        "image/webp",
    ]
    private static let optimizedAttachmentDimensions: [Int] = [2800, 2400, 2000, 1600, 1280, 1024, 768, 640, 512]
    private static let optimizedAttachmentQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]
    private static let optimizedAttachmentMIMEType = "image/jpeg"

    static func submit(
        email: String,
        message: String,
        attachments: [FeedbackComposerAttachment]
    ) async throws {
        guard let endpointURL = FeedbackComposerSettings.endpointURL() else {
            throw FeedbackComposerSubmissionError.invalidEndpoint
        }

        let metadata = FeedbackComposerAppMetadata.current
        let boundary = "Boundary-\(UUID().uuidString)"
        let preparedAttachments = try prepareAttachmentsForUpload(attachments)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        appendField("email", value: email, to: &body, boundary: boundary)
        appendField("message", value: message, to: &body, boundary: boundary)
        appendField("appVersion", value: metadata.appVersion, to: &body, boundary: boundary)
        appendField("appBuild", value: metadata.appBuild, to: &body, boundary: boundary)
        appendField("appCommit", value: metadata.appCommit, to: &body, boundary: boundary)
        appendField("bundleIdentifier", value: metadata.bundleIdentifier, to: &body, boundary: boundary)
        appendField("osVersion", value: metadata.osVersion, to: &body, boundary: boundary)
        appendField("locale", value: metadata.localeIdentifier, to: &body, boundary: boundary)
        appendField("hardwareModel", value: metadata.hardwareModel, to: &body, boundary: boundary)
        appendField("chip", value: metadata.chip, to: &body, boundary: boundary)
        appendField("memoryGB", value: metadata.memoryGB, to: &body, boundary: boundary)
        appendField("architecture", value: metadata.architecture, to: &body, boundary: boundary)
        appendField("displayInfo", value: metadata.displayInfo, to: &body, boundary: boundary)

        for attachment in preparedAttachments {
            appendFile(
                named: "attachments",
                attachment: attachment,
                to: &body,
                boundary: boundary
            )
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw FeedbackComposerSubmissionError.transport(error)
        } catch {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = payload["error"] as? String,
               errorMessage.isEmpty == false {
                #if DEBUG
                NSLog("feedback.submit.rejected status=%@ error=%@", String(httpResponse.statusCode), errorMessage)
                #endif
            }
            throw FeedbackComposerSubmissionError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private static func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private static func prepareAttachmentsForUpload(
        _ attachments: [FeedbackComposerAttachment]
    ) throws -> [PreparedFeedbackComposerAttachment] {
        guard attachments.isEmpty == false else { return [] }

        struct IndexedAttachment {
            let index: Int
            let attachment: FeedbackComposerAttachment
        }

        let sortedAttachments = attachments.enumerated()
            .map { IndexedAttachment(index: $0.offset, attachment: $0.element) }
            .sorted { lhs, rhs in
                lhs.attachment.fileSize > rhs.attachment.fileSize
            }

        var preparedByIndex: [Int: PreparedFeedbackComposerAttachment] = [:]
        var remainingBudget = FeedbackComposerSettings.targetTotalAttachmentUploadBytes
        var remainingCount = sortedAttachments.count

        for item in sortedAttachments {
            let perAttachmentBudget = max(1, remainingBudget / max(remainingCount, 1))
            let preparedAttachment = try prepareAttachmentForUpload(
                item.attachment,
                maximumByteCount: perAttachmentBudget
            )
            preparedByIndex[item.index] = preparedAttachment
            remainingBudget -= preparedAttachment.data.count
            remainingCount -= 1
        }

        let preparedAttachments = attachments.indices.compactMap { preparedByIndex[$0] }
        let totalBytes = preparedAttachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= FeedbackComposerSettings.targetTotalAttachmentUploadBytes else {
            throw FeedbackComposerSubmissionError.attachmentPreparationFailed
        }
        return preparedAttachments
    }

    private static func prepareAttachmentForUpload(
        _ attachment: FeedbackComposerAttachment,
        maximumByteCount: Int
    ) throws -> PreparedFeedbackComposerAttachment {
        if attachment.fileSize > 0,
           attachment.fileSize <= Int64(maximumByteCount),
           passthroughAttachmentMIMETypes.contains(attachment.mimeType),
           let fileData = try? Data(contentsOf: attachment.url, options: .mappedIfSafe) {
            return PreparedFeedbackComposerAttachment(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: fileData
            )
        }

        guard let imageSource = CGImageSourceCreateWithURL(attachment.url as CFURL, nil) else {
            throw FeedbackComposerSubmissionError.attachmentReadFailed
        }

        for maxPixelDimension in optimizedAttachmentDimensions {
            guard let cgImage = downsampledImage(
                from: imageSource,
                maxPixelDimension: maxPixelDimension
            ) else { continue }

            for compressionQuality in optimizedAttachmentQualities {
                guard let jpegData = jpegData(
                    from: cgImage,
                    compressionQuality: compressionQuality
                ) else { continue }
                guard jpegData.count <= maximumByteCount else { continue }

                return PreparedFeedbackComposerAttachment(
                    fileName: optimizedFileName(for: attachment),
                    mimeType: optimizedAttachmentMIMEType,
                    data: jpegData
                )
            }
        }

        throw FeedbackComposerSubmissionError.attachmentPreparationFailed
    }

    private static func downsampledImage(
        from imageSource: CGImageSource,
        maxPixelDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            ] as CFDictionary
        )
    }

    private static func jpegData(
        from image: CGImage,
        compressionQuality: CGFloat
    ) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality,
            ]
        )
    }

    private static func optimizedFileName(
        for attachment: FeedbackComposerAttachment
    ) -> String {
        let baseName = (attachment.fileName as NSString).deletingPathExtension
        return "\(baseName.isEmpty ? "feedback-image" : baseName).jpg"
    }

    private static func appendFile(
        named fieldName: String,
        attachment: PreparedFeedbackComposerAttachment,
        to body: inout Data,
        boundary: String
    ) {
        let sanitizedFileName = attachment.fileName.replacingOccurrences(of: "\"", with: "")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(sanitizedFileName)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(attachment.mimeType)\r\n\r\n".utf8))
        body.append(attachment.data)
        body.append(Data("\r\n".utf8))
    }
}
