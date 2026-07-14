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

    var renderedText: String {
        textChunks.joined()
    }

    func load(path: String, loader: ChatArtifactLoader) async {
        reset(for: path)
        var stat: ChatArtifactStat?
        do {
            let loadedStat = try await loader.stat(path: path)
            try Task.checkCancellation()
            guard path == activePath else { return }
            stat = loadedStat

            guard !loadedStat.isDirectory else {
                state = loadedStat.showsFolder(
                    supportsDirectoryBrowsing: loader.supportsDirectoryBrowsing
                ) ? .folder : .binary(stat: loadedStat)
                return
            }

            let limit = ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes
            guard loadedStat.size <= limit else {
                state = .tooLarge(actualSize: loadedStat.size, limit: limit)
                return
            }

            switch loadedStat.kind {
            case .text:
                try await streamText(path: path, loader: loader)
            case .image, .binary, .directory:
                try await loadNonText(path: path, stat: loadedStat, loader: loader)
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

    private func reset(for path: String) {
        activePath = path
        state = .loading
        textChunks = []
        fetchedBytes = 0
        totalBytes = nil
        textReachedEOF = false
    }

    private func streamText(path: String, loader: ChatArtifactLoader) async throws {
        let decoder = UTF8ChunkDecoder()
        try await loader.stream(path: path) { chunk in
            try Task.checkCancellation()
            let decoded = try await decoder.decode(chunk.data, eof: chunk.eof)
            try Task.checkCancellation()
            await self.receiveText(decoded, chunk: chunk, path: path)
        }
    }

    private func receiveText(_ text: String, chunk: ChatArtifactChunk, path: String) {
        guard path == activePath else { return }
        if !text.isEmpty {
            textChunks.append(text)
        }
        updateProgress(for: chunk)
        textReachedEOF = chunk.eof
        state = .text
    }

    private func loadNonText(
        path: String,
        stat: ChatArtifactStat,
        loader: ChatArtifactLoader
    ) async throws {
        let accumulator = ChatArtifactDataAccumulator()
        try await loader.stream(path: path) { chunk in
            try Task.checkCancellation()
            await accumulator.append(chunk.data, totalSize: chunk.totalSize)
            await self.receiveNonTextProgress(chunk: chunk, path: path)
        }
        try Task.checkCancellation()
        guard path == activePath else { return }
        let data = await accumulator.value()
        switch stat.kind {
        case .image:
            state = .image(data: data)
        case .text:
            break
        case .binary, .directory:
            state = .binary(stat: stat)
        }
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
}
