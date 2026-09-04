import CmuxArtifacts
import Foundation

extension Workspace {
    /// Captures an explicit artifact through the workspace-owned mutation path.
    @MainActor
    @discardableResult
    func captureArtifact(
        _ input: ArtifactInput,
        kind: ArtifactKind? = nil,
        source: ArtifactSource,
        title: String? = nil,
        metadata: [String: String] = [:],
        authorization: ArtifactCaptureAuthorization = .explicitUser,
        capturedAt: Date = .now
    ) async -> ArtifactRecord? {
        await artifactsState.capture(
            input,
            kind: kind,
            source: source,
            title: title,
            metadata: metadata,
            authorization: authorization,
            capturedAt: capturedAt
        )
    }

    /// Captures a browser-saved file with its source page metadata.
    @MainActor
    func captureBrowserDownload(
        at fileURL: URL,
        sourceURL: URL? = nil,
        title: String? = nil,
        capturedAt: Date = .now
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var metadata: [String: String] = ["fileName": fileURL.lastPathComponent]
            if let sourceURL { metadata["sourceURL"] = sourceURL.absoluteString }
            _ = await self.captureArtifact(
                .file(fileURL),
                kind: .browserDownload,
                source: .browserDownload,
                title: title,
                metadata: metadata,
                authorization: .explicitUser,
                capturedAt: capturedAt
            )
        }
    }

    /// Captures bounded HTML from a browser or generated producer.
    @MainActor
    func captureHTML(
        _ html: String,
        source: ArtifactSource = .browser,
        title: String? = nil,
        metadata: [String: String] = [:],
        capturedAt: Date = .now
    ) {
        Task { @MainActor [weak self] in
            _ = await self?.captureArtifact(
                .html(html),
                kind: .html,
                source: source,
                title: title,
                metadata: metadata,
                authorization: .explicitUser,
                capturedAt: capturedAt
            )
        }
    }

    /// Captures generated/local bytes using the explicit producer authorization.
    @MainActor
    func captureGeneratedFile(
        data: Data,
        fileName: String,
        mimeType: String? = nil,
        title: String? = nil,
        capturedAt: Date = .now
    ) {
        Task { @MainActor [weak self] in
            _ = await self?.captureArtifact(
                .data(data, fileName: fileName, mimeType: mimeType),
                source: .generated,
                title: title,
                metadata: mimeType.map { ["mimeType": $0] } ?? [:],
                authorization: .explicitUser,
                capturedAt: capturedAt
            )
        }
    }
}
