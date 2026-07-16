import CmuxAgentChat
import Foundation
import Observation

/// Main-actor state machine for one progressively loaded artifact path.
@Observable
@MainActor
final class ChatArtifactViewerModel {
    private(set) var state: ChatArtifactViewerState = .loading
    private(set) var textChunks: [String] = []
    private(set) var fetchedBytes: Int64 = 0
    private(set) var totalBytes: Int64?
    private(set) var textReachedEOF = false
    private(set) var activePath: String?
    private(set) var activeStat: ChatArtifactStat?
    private(set) var markdownPresentation = ChatArtifactMarkdownPresentation(byteCount: 0)
    private(set) var textHighlightDecision: ChatArtifactHighlightDecision = .skippedNoLanguage
    private(set) var textLineIndex = ChatArtifactLineIndex()
    private let temporaryFileStore: ChatArtifactTemporaryFileStore
    private var temporaryFileURL: URL?

    init(
        temporaryFileStore: ChatArtifactTemporaryFileStore = ChatArtifactTemporaryFileStore()
    ) {
        self.temporaryFileStore = temporaryFileStore
    }

    var renderedText: String {
        textChunks.joined()
    }

    var hasFileActions: Bool {
        guard let activeStat, !activeStat.isDirectory else { return false }
        return state != .loading
    }

    var isTextFile: Bool {
        state == .text || state == .markdown
    }

    var canCopyContents: Bool {
        isTextFile
            && textReachedEOF
            && (activeStat?.size ?? .max) <= Self.maximumCopyContentsBytes
    }

    func load(
        path: String,
        loader: ChatArtifactLoader,
        quickLookCanPreview: @MainActor (URL) -> Bool = { _ in false }
    ) async {
        await removeTemporaryFile()
        reset(for: path)
        var stat: ChatArtifactStat?
        do {
            let loadedStat = try await loader.stat(path: path)
            try Task.checkCancellation()
            guard path == activePath else { return }
            stat = loadedStat
            activeStat = loadedStat
            totalBytes = loadedStat.size
            textHighlightDecision = ChatArtifactSyntaxHighlightPolicy().decision(
                path: path,
                byteCount: loadedStat.size
            )

            let route = ChatArtifactPreviewRouter().route(stat: loadedStat, path: path)
            guard route != .folder else {
                state = loadedStat.showsFolder(
                    supportsDirectoryBrowsing: loader.supportsDirectoryBrowsing
                ) ? .folder : .binary(stat: loadedStat)
                return
            }

            let policy = ChatArtifactTransferPolicy.defaultPolicy
            let limit = route == .media
                ? policy.maxMediaPreviewBytes
                : policy.maxPreviewBytes
            guard loadedStat.size <= limit else {
                state = .tooLarge(actualSize: loadedStat.size, limit: limit)
                return
            }

            switch route {
            case .text:
                try await streamText(
                    path: path,
                    stat: loadedStat,
                    isMarkdown: false,
                    loader: loader
                )
            case .markdown:
                markdownPresentation = ChatArtifactMarkdownPresentation(
                    byteCount: loadedStat.size
                )
                try await streamText(
                    path: path,
                    stat: loadedStat,
                    isMarkdown: true,
                    loader: loader
                )
            case .image:
                try await loadImage(path: path, stat: loadedStat, loader: loader)
            case .pdf:
                if let fileURL = try await loadTemporaryFile(
                    path: path,
                    expectedSize: loadedStat.size,
                    modifiedAt: loadedStat.modifiedAt,
                    limit: limit,
                    fallbackExtension: "pdf",
                    loader: loader
                ) {
                    state = .pdf(fileURL: fileURL)
                }
            case .media:
                if let fileURL = try await loadTemporaryFile(
                    path: path,
                    expectedSize: loadedStat.size,
                    modifiedAt: loadedStat.modifiedAt,
                    limit: limit,
                    fallbackExtension: ChatArtifactPreviewRouter()
                        .preferredExtension(forMIMEType: loadedStat.mimeType),
                    loader: loader
                ) {
                    state = .media(fileURL: fileURL)
                }
            case .quickLook:
                if let fileURL = try await loadTemporaryFile(
                    path: path,
                    expectedSize: loadedStat.size,
                    modifiedAt: loadedStat.modifiedAt,
                    limit: limit,
                    fallbackExtension: nil,
                    loader: loader
                ) {
                    if quickLookCanPreview(fileURL) {
                        state = .quickLook(fileURL: fileURL)
                    } else {
                        await removeTemporaryFile()
                        state = .binary(stat: loadedStat)
                    }
                }
            case .binary:
                state = .binary(stat: loadedStat)
            case .folder:
                break
            }
        } catch is CancellationError {
            return
        } catch is UTF8ChunkAssemblerError {
            guard path == activePath, let stat else { return }
            textChunks = []
            state = .binary(stat: stat)
        } catch {
            guard !Task.isCancelled, path == activePath else { return }
            state = Self.state(for: error, stat: stat)
        }
    }

    func cleanup() async {
        await removeTemporaryFile()
    }

    func selectMarkdownMode(_ mode: ChatArtifactMarkdownMode) {
        markdownPresentation.select(mode)
    }

    private func reset(for path: String) {
        activePath = path
        activeStat = nil
        state = .loading
        textChunks = []
        fetchedBytes = 0
        totalBytes = nil
        textReachedEOF = false
        markdownPresentation = ChatArtifactMarkdownPresentation(byteCount: 0)
        textHighlightDecision = .skippedNoLanguage
        textLineIndex = ChatArtifactLineIndex()
    }

    private func streamText(
        path: String,
        stat: ChatArtifactStat,
        isMarkdown: Bool,
        loader: ChatArtifactLoader
    ) async throws {
        let decoder = UTF8ChunkDecoder()
        try await loader.stream(
            path: path,
            modifiedAt: stat.modifiedAt,
            size: stat.size
        ) { chunk in
            try Task.checkCancellation()
            let decodedBatches = try await decoder.decodeBatches(chunk.data, eof: chunk.eof)
            try Task.checkCancellation()
            if decodedBatches.isEmpty {
                await self.receiveText(
                    "",
                    chunk: chunk,
                    path: path,
                    isMarkdown: isMarkdown,
                    isFinalBatch: true
                )
            } else {
                for (index, decoded) in decodedBatches.enumerated() {
                    try Task.checkCancellation()
                    let isFinalBatch = index == decodedBatches.index(before: decodedBatches.endIndex)
                    let lineIndexBatch = await Task.detached(priority: .userInitiated) {
                        ChatArtifactLineIndexBatch(text: decoded)
                    }.value
                    try Task.checkCancellation()
                    await self.receiveText(
                        decoded,
                        lineIndexBatch: lineIndexBatch,
                        chunk: chunk,
                        path: path,
                        isMarkdown: isMarkdown,
                        isFinalBatch: isFinalBatch
                    )
                    if !isFinalBatch {
                        await Task.yield()
                    }
                }
            }
        }
    }

    private func receiveText(
        _ text: String,
        lineIndexBatch: ChatArtifactLineIndexBatch? = nil,
        chunk: ChatArtifactChunk,
        path: String,
        isMarkdown: Bool,
        isFinalBatch: Bool
    ) {
        guard path == activePath else { return }
        if !text.isEmpty {
            textChunks.append(text)
            if let lineIndexBatch {
                textLineIndex.append(lineIndexBatch)
            } else {
                textLineIndex.append(text)
            }
        }
        if isFinalBatch {
            updateProgress(for: chunk)
            textReachedEOF = chunk.eof
        }
        state = isMarkdown ? .markdown : .text
    }

    private func loadImage(
        path: String,
        stat: ChatArtifactStat,
        loader: ChatArtifactLoader
    ) async throws {
        let accumulator = ChatArtifactDataAccumulator()
        try await loader.stream(
            path: path,
            modifiedAt: stat.modifiedAt,
            size: stat.size
        ) { chunk in
            try Task.checkCancellation()
            await accumulator.append(chunk.data, totalSize: chunk.totalSize)
            await self.receiveNonTextProgress(chunk: chunk, path: path)
        }
        try Task.checkCancellation()
        guard path == activePath else { return }
        let data = await accumulator.value()
        state = .image(data: data)
    }

    private func loadTemporaryFile(
        path: String,
        expectedSize: Int64,
        modifiedAt: Date?,
        limit: Int64,
        fallbackExtension: String?,
        loader: ChatArtifactLoader
    ) async throws -> URL? {
        let fileURL = try await temporaryFileStore.fetch(
            path: path,
            expectedSize: expectedSize,
            modifiedAt: modifiedAt,
            limit: limit,
            fallbackExtension: fallbackExtension,
            loader: loader
        ) { chunk in
            await self.receiveNonTextProgress(chunk: chunk, path: path)
        }
        guard path == activePath else {
            await temporaryFileStore.remove(fileURL)
            return nil
        }
        temporaryFileURL = fileURL
        return fileURL
    }

    private func receiveNonTextProgress(chunk: ChatArtifactChunk, path: String) {
        guard path == activePath else { return }
        updateProgress(for: chunk)
    }

    private func updateProgress(for chunk: ChatArtifactChunk) {
        totalBytes = chunk.totalSize
        fetchedBytes = chunk.eof
            ? chunk.totalSize
            : chunk.offset + Int64(chunk.data.count)
    }

    private func removeTemporaryFile() async {
        guard let temporaryFileURL else { return }
        self.temporaryFileURL = nil
        await temporaryFileStore.remove(temporaryFileURL)
    }

    private static func state(
        for error: any Error,
        stat: ChatArtifactStat?
    ) -> ChatArtifactViewerState {
        guard let artifactError = error as? ChatArtifactError else {
            return .macUnreachable
        }
        switch artifactError {
        case .fileNotFound:
            return .fileMissing
        case .forbidden:
            return .forbidden
        case .macUnreachable, .unavailable, .unsupported, .sessionNotFound, .invalidParams:
            return .macUnreachable
        case .unsupportedMedia:
            return .unsupportedMedia
        case .tooLarge(let limitBytes):
            return .tooLarge(actualSize: stat?.size, limit: limitBytes)
        }
    }

    private static let maximumCopyContentsBytes: Int64 = 4 * 1024 * 1024
}
