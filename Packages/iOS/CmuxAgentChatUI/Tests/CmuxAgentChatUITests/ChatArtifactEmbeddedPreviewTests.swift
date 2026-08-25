import Foundation
import Testing
@testable import CmuxAgentChatUI

@MainActor
struct ChatArtifactEmbeddedPreviewTests {
    @Test func constructsWithPanelScopedLoader() {
        let loader = ChatArtifactLoader(
            panelWorkspaceID: "ws-1",
            panelSurfaceID: "surface-1",
            supportsArtifacts: true,
            stat: { _ in throw ChatArtifactErrorFixture.unsupported },
            fetch: { _, _ in throw ChatArtifactErrorFixture.unsupported },
            thumbnail: { _, _ in throw ChatArtifactErrorFixture.unsupported }
        )
        _ = ChatArtifactEmbeddedPreview(
            path: "/tmp/demo.md",
            scope: .panel,
            loader: loader,
            refreshToken: "demo.md"
        )
        // Panel scopes are one-file allowlists; the embedded host must never
        // reach the folder browser.
        #expect(loader.supportsDirectoryBrowsing == false)
        #expect(loader.scope == .panel(workspaceID: "ws-1", surfaceID: "surface-1"))
    }

    @Test func refreshTokenChurnReStatsViaRetryGeneration() {
        // The embedded page maps refresh-token changes onto the page model's
        // retry generation, which keys the route view's load task.
        let model = ChatArtifactViewerPageModel(
            path: "/tmp/demo.md",
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        )
        let initial = model.snapshot.retryGeneration
        model.retry()
        #expect(model.snapshot.retryGeneration == initial + 1)
        #expect(model.snapshot.path == "/tmp/demo.md")
    }
}

private enum ChatArtifactErrorFixture: Error {
    case unsupported
}
