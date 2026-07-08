import CmuxAgentChat
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum TerminalControllerChatArtifactIndexProvider {
    static let shared = AgentChatArtifactIndex()
}

extension TerminalController {
    func v2MobileChatArtifactStat(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        do {
            let stat = try await Task.detached {
                try ChatArtifactFileIO.stat(path: resolved.canonicalPath)
            }.value
            return .ok(ChatArtifactWire.payload(stat) ?? [:])
        } catch ChatArtifactFileIO.Error.fileNotFound {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch ChatArtifactFileIO.Error.unsupportedMedia {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
        } catch {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactFetch(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        let offset = max(0, Int64(v2Int(params, "offset") ?? 0))
        let length = ChatArtifactTransferPolicy.defaultPolicy
            .clampedChunkLength(v2Int(params, "length"))
        do {
            let chunk = try await Task.detached {
                try ChatArtifactFileIO.fetch(path: resolved.canonicalPath, offset: offset, length: length)
            }.value
            return .ok(ChatArtifactWire.payload(chunk) ?? [:])
        } catch ChatArtifactFileIO.Error.fileNotFound {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactThumbnail(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        let maxDimension = min(max(v2Int(params, "max_dimension") ?? 512, 64), 1024)
        do {
            let thumbnail = try await Task.detached {
                try ChatArtifactFileIO.thumbnail(path: resolved.canonicalPath, maxDimension: maxDimension)
            }.value
            return .ok(ChatArtifactWire.payload(thumbnail) ?? [:])
        } catch ChatArtifactFileIO.Error.unsupportedMedia {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
        } catch ChatArtifactFileIO.Error.fileNotFound {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactList(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .list)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        do {
            let listing = try await Task.detached {
                try ChatArtifactFileIO.list(path: resolved.canonicalPath)
            }.value
            return .ok(ChatArtifactWire.payload(listing) ?? [:])
        } catch ChatArtifactFileIO.Error.fileNotFound {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        }
    }

    private enum ChatArtifactOperation {
        case file
        case list

        var indexOperation: AgentChatArtifactIndex.Operation {
            switch self {
            case .file:
                return .file
            case .list:
                return .list
            }
        }
    }

    private struct ResolvedChatArtifact: Sendable {
        let requestedPath: String
        let canonicalPath: String
    }

    private enum ChatArtifactResolution {
        case success(ResolvedChatArtifact)
        case failure(V2CallResult)

        var failureResult: V2CallResult {
            switch self {
            case .success:
                return .err(code: "internal_error", message: "unexpected success", data: nil)
            case .failure(let result):
                return result
            }
        }
    }

    private func mobileChatArtifactResolution(
        params: [String: Any],
        operation: ChatArtifactOperation
    ) async -> ChatArtifactResolution {
        guard let sessionID = v2RawString(params, "session_id"),
              let requestedPath = v2RawString(params, "path"),
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.chat.artifact.error.invalidParams",
                    defaultValue: "session_id and path are required."
                ),
                data: nil
            ))
        }
        guard let service = agentChatTranscriptService else {
            return .failure(.err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil))
        }
        guard let record = service.sessionRecord(sessionID: sessionID) else {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
        }
        guard let transcriptPath = service.resolver.transcriptPath(for: record) else {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
        }
        do {
            let canonicalPath = try await TerminalControllerChatArtifactIndexProvider.shared.canonicalPath(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                transcriptPath: transcriptPath,
                requestedPath: requestedPath,
                operation: operation.indexOperation
            )
            guard let canonicalPath else {
                return .failure(mobileChatArtifactError(.forbidden, path: requestedPath))
            }
            return .success(ResolvedChatArtifact(requestedPath: requestedPath, canonicalPath: canonicalPath))
        } catch {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
        }
    }

    private enum MobileChatArtifactErrorKind {
        case notFound
        case forbidden
        case fileNotFound
        case unsupportedMedia
    }

    private func mobileChatArtifactError(
        _ kind: MobileChatArtifactErrorKind,
        path: String
    ) -> V2CallResult {
        switch kind {
        case .notFound:
            return .err(
                code: "not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.sessionNotFound",
                    defaultValue: "That agent session is no longer available."
                ),
                data: nil
            )
        case .forbidden:
            return .err(
                code: "forbidden",
                message: String(
                    localized: "mobile.chat.artifact.error.forbidden",
                    defaultValue: "That file was not referenced by this conversation."
                ),
                data: ["path": path]
            )
        case .fileNotFound:
            return .err(
                code: "file_not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.fileNotFound",
                    defaultValue: "That file is no longer available on the Mac."
                ),
                data: ["path": path]
            )
        case .unsupportedMedia:
            return .err(
                code: "unsupported_media",
                message: String(
                    localized: "mobile.chat.artifact.error.unsupportedMedia",
                    defaultValue: "This file type cannot be previewed."
                ),
                data: ["path": path]
            )
        }
    }
}

private struct ChatArtifactWire {
    static func payload<T: Encodable>(_ value: T) -> [String: Any]? {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private struct ChatArtifactFileIO {
    enum Error: Swift.Error {
        case fileNotFound
        case unsupportedMedia
    }

    static func stat(path: String) throws -> ChatArtifactStat {
        let attributes = try attributes(path: path)
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let kind = artifactKind(path: path, isDirectory: isDirectory)
        return ChatArtifactStat(
            exists: true,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt,
            kind: kind,
            mimeType: mimeType(path: path, isDirectory: isDirectory)
        )
    }

    static func fetch(path: String, offset: Int64, length: Int) throws -> ChatArtifactChunk {
        let stat = try stat(path: path)
        guard !stat.isDirectory else { throw Error.unsupportedMedia }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw Error.fileNotFound
        }
        defer { try? handle.close() }
        let totalSize = stat.size
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

    static func thumbnail(path: String, maxDimension: Int) throws -> ChatArtifactThumbnail {
        guard artifactKind(path: path, isDirectory: false) == .image else {
            throw Error.unsupportedMedia
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.fileNotFound
        }
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

    static func list(path: String) throws -> ChatArtifactDirectoryListing {
        let stat = try stat(path: path)
        guard stat.isDirectory else { throw Error.fileNotFound }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        let listed = try entries
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(500)
            .map { entry -> ChatArtifactDirectoryEntry in
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values.isDirectory ?? false
                return ChatArtifactDirectoryEntry(
                    name: entry.lastPathComponent,
                    isDirectory: isDirectory,
                    size: Int64(values.fileSize ?? 0),
                    kind: artifactKind(path: entry.path, isDirectory: isDirectory)
                )
            }
        return ChatArtifactDirectoryListing(entries: listed)
    }

    private static func attributes(path: String) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw Error.fileNotFound
        }
    }

    private static func artifactKind(path: String, isDirectory: Bool) -> ChatArtifactKind {
        if isDirectory { return .directory }
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return .binary
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    private static func mimeType(path: String, isDirectory: Bool) -> String? {
        guard !isDirectory,
              let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }
}
