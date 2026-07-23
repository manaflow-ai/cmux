import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShellModel
import Foundation
import Observation

/// Main-actor load state for one panel-scoped markdown surface.
@MainActor
@Observable
final class MarkdownSurfaceModel {
    /// Failure vocabulary mirroring the artifact viewer's inline states.
    enum Failure: Equatable {
        case fileMissing
        case forbidden
        case macUnreachable
        case tooLarge(actualSize: Int64?, limit: Int64)
    }

    enum Phase: Equatable {
        case loading
        case loaded(text: String)
        case failed(Failure)
    }

    private(set) var phase: Phase = .loading
    private(set) var fetchedBytes: Int64 = 0
    private(set) var totalBytes: Int64?
    /// The path the current phase describes, so stale loads never publish.
    private var activePath: String?
    private var collected = Data()

    /// Stats, streams, and decodes the panel's markdown file.
    ///
    /// UTF-8 with an ISO-Latin-1 fallback (`MacSurfaceTextDecoder`), so any
    /// byte payload within the preview size limit renders as text.
    func load(path: String, loader: ChatArtifactLoader) async {
        activePath = path
        phase = .loading
        fetchedBytes = 0
        totalBytes = nil
        collected = Data()
        do {
            let stat = try await loader.stat(path: path)
            try Task.checkCancellation()
            guard path == activePath else { return }
            totalBytes = stat.size
            let limit = ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes
            guard stat.size <= limit else {
                phase = .failed(.tooLarge(actualSize: stat.size, limit: limit))
                return
            }
            try await loader.stream(
                path: path,
                modifiedAt: stat.modifiedAt,
                size: stat.size
            ) { chunk in
                try Task.checkCancellation()
                await self.receive(chunk, path: path)
            }
            try Task.checkCancellation()
            guard path == activePath else { return }
            phase = .loaded(text: MacSurfaceTextDecoder.decode(collected).text)
            collected = Data()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, path == activePath else { return }
            phase = .failed(Self.failure(for: error))
        }
    }

    private func receive(_ chunk: ChatArtifactChunk, path: String) {
        guard path == activePath else { return }
        collected.append(chunk.data)
        totalBytes = chunk.totalSize
        fetchedBytes = chunk.eof
            ? chunk.totalSize
            : chunk.offset + Int64(chunk.data.count)
    }

    private static func failure(for error: any Error) -> Failure {
        guard let artifactError = error as? ChatArtifactError else {
            return .macUnreachable
        }
        switch artifactError {
        case .fileNotFound:
            return .fileMissing
        case .forbidden:
            return .forbidden
        case .tooLarge(let limitBytes):
            return .tooLarge(actualSize: nil, limit: limitBytes)
        case .macUnreachable, .unavailable, .unsupported, .sessionNotFound,
             .invalidParams, .unsupportedMedia:
            return .macUnreachable
        }
    }
}
