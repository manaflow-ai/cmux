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

    @Test func genericSocketDraftBlocksAnAtomicPromptSubmission() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.socket-draft"
        )

        #expect(fixture.surface.sendInputResult("phone draft").accepted)
        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(
            fixture.surface.sendPromptSubmission(
                "supervisor prompt",
                submitKey: "return"
            ) == .composerBusy
        )

        let pending = fixture.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 1)
        #expect(pending.inputTextItems == 1)
        #expect(pending.promptSubmissionItems == 0)
    }

    @Test func genericSocketReturnRequiresAHookBeforeClearingOwnership() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.socket-submit"
        )

        #expect(
            fixture.surface.sendInputResult("phone prompt\r").accepted
        )
        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "phone prompt"
            ) == .human
        )
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func genericPasteAndNamedReturnShareTheOwnershipLedger() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.paste-submit"
        )

        #expect(fixture.surface.sendText("pasted draft"))
        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(fixture.surface.sendNamedKey("return").accepted)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "pasted draft"
            ) == .human
        )
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func configuredControlReturnCreatesARecoverableBoundary() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:claude.session",
            controlReturnIsPromptSubmissionBoundary: true
        )

        #expect(fixture.surface.sendText("first line\nsecond line"))
        #expect(fixture.surface.sendNamedKey("ctrl+enter").accepted)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "first line second line"
            ) == .human
        )
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func unconfiguredControlReturnRemainsFailClosed() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.session",
            controlReturnIsPromptSubmissionBoundary: false
        )

        #expect(fixture.surface.sendText("draft"))
        #expect(fixture.surface.sendNamedKey("ctrl+enter").accepted)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "not a known boundary"
            ) == .unmatched
        )
        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func acceptedExternalInputUsesTheGenericInputLedgerGrammar() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.remote-input"
        )

        fixture.surface.recordAcceptedUnownedPromptInput(
            "\u{1B}]0;title\u{7}remote prompt\r"
        )

        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "remote prompt"
            ) == .human
        )
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func acceptedExternalNamedReturnCreatesARecoverableBoundary() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.remote-key"
        )

        fixture.surface.recordAcceptedUnownedPromptInput("remote draft")
        fixture.surface.recordAcceptedUnownedPromptKey("return")

        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "remote draft"
            ) == .human
        )
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func promptPreparationQueuesInsideOneAppOwnedCompoundItem() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.preparation"
        )

        #expect(
            fixture.surface.sendPromptSubmission(
                "first line\nsecond line",
                submitKey: "return",
                preparationKeys: ["ctrl+a", "ctrl+k", "ctrl+u"],
                hookRecordingSource: "workspace.agent_submit"
            ) == .queued
        )

        let pending = fixture.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(pending.pasteTextItems == 0)
        #expect(pending.keyEvents == 0)
        #expect(
            fixture.surface.pendingPromptPreparationKeyLabelsForTests
                == [["ctrl+a", "ctrl+k", "ctrl+u"]]
        )
        #expect(
            pending.bytes
                == Data("first line\nsecond line".utf8).count
                    + "ctrl+a".utf8.count
                    + "ctrl+k".utf8.count
                    + "ctrl+u".utf8.count
                    + "return".utf8.count
        )
        #expect(fixture.paneHost.explicitInputCount == 1)
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(
            fixture.surface.confirmPromptSubmission(
                message: "first line second line"
            ) == .unmatched
        )
    }

    @Test func invalidPromptPreparationRejectsBeforeQueueMutation() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(
            fixture.surface.sendPromptSubmission(
                "supervisor prompt",
                submitKey: "return",
                preparationKeys: ["ctrl+a", "unsupported-preparation"]
            ) == .unknownKey
        )

        #expect(fixture.surface.pendingSocketInputSnapshotForTests.items == 0)
        #expect(!fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(fixture.paneHost.explicitInputCount == 0)
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

        let pending = fixture.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 0)
        #expect(fixture.surface.hasUnconfirmedHumanPromptInput)
        #expect(fixture.paneHost.explicitInputCount == 0)
    }

    @Test func rejectedOversizedPromptDoesNotNotifyPaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(
            fixture.surface.sendPromptSubmission(
                String(repeating: "x", count: 1_048_577),
                submitKey: "return"
            ) == .inputQueueFull
        )

        #expect(fixture.surface.pendingSocketInputSnapshotForTests.items == 0)
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
        let pending = fixture.surface.pendingSocketInputSnapshotForTests
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

private extension TerminalSurface {
    var pendingPromptPreparationKeyLabelsForTests: [[String]] {
        pendingSocketInputQueue.compactMap { item -> [String]? in
            guard case .promptSubmission(
                let preparationKeys,
                _,
                _,
                _,
                _
            ) = item else {
                return nil
            }
            return preparationKeys.map(\.label)
        }
    }

    var pendingSocketInputSnapshotForTests: (
        items: Int,
        bytes: Int,
        keyEvents: Int,
        pasteTextItems: Int,
        promptSubmissionItems: Int,
        inputTextItems: Int,
        processOutputItems: Int
    ) {
        let counts = pendingSocketInputQueue.reduce(
            into: (
                keyEvents: 0,
                pasteTextItems: 0,
                promptSubmissionItems: 0,
                inputTextItems: 0,
                processOutputItems: 0
            )
        ) { counts, item in
            switch item {
            case .key:
                counts.keyEvents += 1
            case .pasteText:
                counts.pasteTextItems += 1
            case .promptSubmission:
                counts.promptSubmissionItems += 1
            case .inputText:
                counts.inputTextItems += 1
            case .processOutput:
                counts.processOutputItems += 1
            }
        }
        return (
            pendingSocketInputQueue.count,
            pendingSocketInputBytes,
            counts.keyEvents,
            counts.pasteTextItems,
            counts.promptSubmissionItems,
            counts.inputTextItems,
            counts.processOutputItems
        )
    }
}
