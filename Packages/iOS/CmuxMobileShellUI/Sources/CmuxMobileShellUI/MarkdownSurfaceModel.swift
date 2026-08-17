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
        /// The panel that authorized this file is no longer open.
        case panelClosed
        /// The Mac answered but predates the panel preview RPCs.
        case macNeedsUpdate
        /// The Mac's transfer service is temporarily unavailable.
        case transferUnavailable
        /// The Mac answered with an unrecognized or malformed error.
        case loadFailed(code: String?)
    }

    enum Phase: Equatable {
        case loading
        case loaded(text: String)
        case failed(Failure)
    }

    private(set) var phase: Phase = .loading
    private(set) var fetchedBytes: Int64 = 0
    private(set) var totalBytes: Int64?
    /// Generation of the newest `load` call. A restarted load for the SAME
    /// path (retry, title churn) must also invalidate in-flight chunks from
    /// the superseded stream, so staleness is guarded by generation rather
    /// than path equality.
    private var loadGeneration: UInt64 = 0
    private var collected = Data()

    /// Stats, streams, and decodes the panel's markdown file.
    ///
    /// UTF-8 with an ISO-Latin-1 fallback (`MacSurfaceTextDecoder`), so any
    /// byte payload within the preview size limit renders as text.
    func load(path: String, loader: ChatArtifactLoader) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        phase = .loading
        fetchedBytes = 0
        totalBytes = nil
        collected = Data()
        do {
            let stat = try await loader.stat(path: path)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
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
                await self.receive(chunk, generation: generation)
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            phase = .loaded(text: MacSurfaceTextDecoder.decode(collected).text)
            collected = Data()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            phase = .failed(Self.failure(for: error))
        }
    }

    private func receive(_ chunk: ChatArtifactChunk, generation: UInt64) {
        guard generation == loadGeneration else { return }
        collected.append(chunk.data)
        totalBytes = chunk.totalSize
        fetchedBytes = chunk.eof
            ? chunk.totalSize
            : chunk.offset + Int64(chunk.data.count)
    }

    static func failure(for error: any Error) -> Failure {
        guard let artifactError = error as? ChatArtifactError else {
            // The Mac replied with something undecodable; connectivity was
            // fine, so the message must not claim the Mac is unreachable.
            return .loadFailed(code: nil)
        }
        switch artifactError {
        case .unsupported:
            return .macNeedsUpdate
        case .invalidParams:
            return .loadFailed(code: "invalid_params")
        case .fileNotFound:
            return .fileMissing
        case .forbidden, .permissionDenied, .authorizationFailed, .secureConnectionRequired, .authenticationExpired:
            return .forbidden
        case .tooLarge(let limitBytes):
            return .tooLarge(actualSize: nil, limit: limitBytes)
        case .macUnreachable, .accountMismatch:
            return .macUnreachable
        case .sessionNotFound, .terminalNotFound, .workspaceNotFound:
            return .panelClosed
        case .sessionUnavailable, .unavailable, .fileChanged, .transferInterrupted,
             .requestTimedOut, .connectionRecovering:
            return .transferUnavailable
        case .notRepository, .notDirectory, .notRegularFile, .fileReadFailed,
             .unsupportedMedia, .corruptMedia, .previewFailed, .invalidResponse,
             .connectionNeedsRestart, .localStorageFull, .localStorageUnavailable,
             .loadFailed:
            // A markdown panel path that stops decoding as text is a data
            // problem on the Mac side, not connectivity.
            return .loadFailed(code: nil)
        case .unknown(let code):
            return .loadFailed(code: code)
        }
    }
}
