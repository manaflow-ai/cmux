import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite(.serialized)
struct TerminalSurfaceExplicitInputTests {
    @Test func pasteTextNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendText("hello"))

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func parsedInputNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendInputResult("hello").accepted)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func namedKeyNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendNamedKey("enter").accepted)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func promptSubmissionQueuesAsOneCompoundItemOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(
            fixture.surface.sendPromptSubmission(
                "first line\nsecond line",
                submitKey: "return",
                hookRecordingSource: "workspace.agent_submit"
            ) == .queued
        )

        let pending = fixture.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(pending.pasteTextItems == 0)
        #expect(pending.keyEvents == 0)
        #expect(
            pending.bytes
                == Data("first line\nsecond line".utf8).count
                    + "return".utf8.count
        )
        #expect(fixture.paneHost.explicitInputCount == 1)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "first line second line"
            ) == .unmatched
        )
    }

    @Test func promptSubmissionRejectsWithoutChangingARecordedHumanDraft() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.recordHumanPromptInput(.unknown)

        #expect(
            fixture.surface.sendPromptSubmission(
                "supervisor prompt",
                submitKey: "return"
            ) == .composerBusy
        )

        let pending = fixture.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 0)
        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(fixture.paneHost.explicitInputCount == 0)
    }

    @Test func emptyPromptStillQueuesItsSubmitKeyAsACompoundItem() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(
            fixture.surface.sendPromptSubmission(
                "",
                submitKey: "return",
                hookRecordingSource: "workspace.agent_submit"
            ) == .queued
        )
        let pending = fixture.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(pending.pasteTextItems == 0)
        #expect(pending.keyEvents == 0)
        #expect(pending.bytes == "return".utf8.count)
        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func keyTextNotifiesPaneHostBeforeWritingToALiveSurface() {
        let fixture = makeFixture()
        fixture.surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        defer { fixture.surface.releaseSurfaceForTesting() }

        _ = fixture.surface.sendKeyText("x")

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func explicitBindingActionNotifiesWithoutChangingInternalBindingActions() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(!fixture.surface.performBindingAction("scroll_to_bottom"))
        #expect(fixture.paneHost.explicitInputCount == 0)

        #expect(!fixture.surface.performExplicitInputBindingAction("paste_from_clipboard"))
        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func closingSearchAsExplicitInputNotifiesBeforeClearingSearchState() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.searchState = TerminalSurface.SearchState(needle: "scroll")

        fixture.surface.closeSearchFromExplicitInput()

        #expect(fixture.paneHost.explicitInputCount == 1)
        #expect(fixture.surface.searchState == nil)
    }

    @Test func copyModeToggleNotifiesPaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(!fixture.surface.toggleKeyboardCopyMode())

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func mobileGesturesNotifyPaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        fixture.surface.mobileScroll(deltaLines: 1, col: 0, row: 0)
        fixture.surface.mobileClick(col: 0, row: 0)

        #expect(fixture.paneHost.explicitInputCount == 2)
    }

    @Test func emptyMobileScrollDoesNotNotifyPaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        fixture.surface.mobileScroll(deltaLines: 0, col: 0, row: 0)

        #expect(fixture.paneHost.explicitInputCount == 0)
    }

    @Test func emptyInputDoesNotNotifyThePaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendText(""))
        #expect(fixture.surface.sendKeyText(""))
        #expect(fixture.surface.sendInputResult("").accepted)
        #expect(fixture.surface.sendNamedKey("") == .unknownKey)

        #expect(fixture.paneHost.explicitInputCount == 0)
    }

    @Test func paneHostPreparationRunsBeforeStartupWorkCanAttachTheRuntime() {
        var events: [String] = []
        let fixture = makeFixture(
            initialInput: "echo ready",
            preparePaneHost: { _ in events.append("prepare") },
            onAttach: { events.append("attach") }
        )
        defer {
            fixture.surface.closeHeadlessStartupWindowIfNeeded()
            fixture.surface.releaseSurfaceForTesting()
        }

        #expect(events.first == "prepare")
        #expect(events.dropFirst().contains("attach"))
    }

    private func makeFixture(
        initialInput: String? = nil,
        preparePaneHost: @Sendable @MainActor (any TerminalSurfacePaneHosting) -> Void = { _ in },
        onAttach: (() -> Void)? = nil
    ) -> (surface: TerminalSurface, paneHost: FakeTerminalSurfacePaneHost) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView, onAttach: onAttach)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: initialInput,
            preparePaneHost: preparePaneHost,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        return (surface, paneHost)
    }

    private func fakeRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x7540)!
    }
}
