import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite(.serialized)
struct TerminalSurfaceBootstrapSizingTests {
    @Test func preLayoutSurfaceUsesMinimalNonzeroBounds() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.viewProvider.requestedInitialFrame == NSRect(x: 0, y: 0, width: 1, height: 1))
        #expect(fixture.surface.surfaceView.bounds.size == CGSize(width: 1, height: 1))
    }

    @Test func headlessStartupExpandsMinimalBoundsToEightHundredBySixHundred() throws {
        let fixture = makeFixture(initialInput: "echo ready")
        defer {
            fixture.surface.closeHeadlessStartupWindowIfNeeded()
            fixture.surface.releaseSurfaceForTesting()
        }

        let window = try #require(fixture.paneHost.window)
        #expect(fixture.surface.isHeadlessStartupWindow(window))
        #expect(window.contentView?.bounds.size == CGSize(width: 800, height: 600))
    }

    private func makeFixture(
        initialInput: String? = nil
    ) -> (
        surface: TerminalSurface,
        paneHost: FakeTerminalSurfacePaneHost,
        viewProvider: RecordingTerminalSurfaceViewProvider
    ) {
        let viewProvider = RecordingTerminalSurfaceViewProvider()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: initialInput,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: viewProvider,
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("cmux-terminal-tests", isDirectory: true),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        return (surface, viewProvider.paneHost, viewProvider)
    }
}

@MainActor
private final class RecordingTerminalSurfaceViewProvider: TerminalSurfaceViewProviding {
    let surfaceView = FakeTerminalSurfaceNativeView(frame: .zero)
    lazy var paneHost = FakeTerminalSurfacePaneHost(surfaceView: surfaceView)
    private(set) var requestedInitialFrame: NSRect?

    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        requestedInitialFrame = initialFrame
        surfaceView.frame = initialFrame
        paneHost.frame = initialFrame
        return (surfaceView, paneHost)
    }
}
