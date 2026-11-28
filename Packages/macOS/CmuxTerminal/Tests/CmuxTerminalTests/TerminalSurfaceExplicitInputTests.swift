import AppKit
import Carbon.HIToolbox
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_surface_key_reset")
private func cmuxTestGhosttySurfaceKeyReset()

@_silgen_name("cmux_test_ghostty_surface_key_was_called")
private func cmuxTestGhosttySurfaceKeyWasCalled() -> Bool

@_silgen_name("cmux_test_ghostty_surface_key_mods")
private func cmuxTestGhosttySurfaceKeyMods() -> Int32

@_silgen_name("cmux_test_ghostty_surface_key_unshifted_codepoint")
private func cmuxTestGhosttySurfaceKeyUnshiftedCodepoint() -> UInt32

@_silgen_name("cmux_test_ghostty_surface_key_text")
private func cmuxTestGhosttySurfaceKeyText() -> UnsafePointer<CChar>

@_silgen_name("cmux_test_ghostty_input_events_reset")
private func cmuxTestGhosttyInputEventsReset()

@_silgen_name("cmux_test_ghostty_input_event_count")
private func cmuxTestGhosttyInputEventCount() -> UInt32

@_silgen_name("cmux_test_ghostty_input_event_kind")
private func cmuxTestGhosttyInputEventKind(_ index: UInt32) -> Int32

@_silgen_name("cmux_test_ghostty_surface_size_set")
private func cmuxTestGhosttySurfaceSizeSet(_ cellWidthPx: UInt32, _ cellHeightPx: UInt32)

@_silgen_name("cmux_test_ghostty_mouse_scroll_reset")
private func cmuxTestGhosttyMouseScrollReset()

@_silgen_name("cmux_test_ghostty_mouse_scroll_call_count")
private func cmuxTestGhosttyMouseScrollCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_mouse_scroll_last_x")
private func cmuxTestGhosttyMouseScrollLastX() -> Double

@_silgen_name("cmux_test_ghostty_mouse_scroll_last_y")
private func cmuxTestGhosttyMouseScrollLastY() -> Double

@_silgen_name("cmux_test_ghostty_mouse_scroll_last_mods")
private func cmuxTestGhosttyMouseScrollLastMods() -> Int32

@MainActor
@Suite(.serialized)
struct TerminalSurfaceExplicitInputTests {
    enum ProgrammaticInput: CaseIterable, Equatable, Sendable {
        case pasteText
        case keyText
        case namedKey
        case parsedInput
        case bindingAction
        case mobileScroll
        case mobileClick

        var expectedExplicitInputCount: Int {
            self == .bindingAction ? 0 : 1
        }

        @MainActor
        func send(to surface: TerminalSurface) {
            switch self {
            case .pasteText:
                _ = surface.sendText("hello")
            case .keyText:
                _ = surface.sendKeyText("x")
            case .namedKey:
                _ = surface.sendNamedKey("enter")
            case .parsedInput:
                _ = surface.sendInputResult("hello")
            case .bindingAction:
                _ = surface.performBindingAction("scroll_to_bottom")
            case .mobileScroll:
                surface.mobileScroll(deltaLines: 1, col: 0, row: 0)
            case .mobileClick:
                surface.mobileClick(col: 0, row: 0)
            }
        }
    }

    @Test(
        "programmatic input waits for a runtime clipboard read",
        arguments: ProgrammaticInput.allCases
    )
    func programmaticInputWaitsForRuntimeClipboardRead(
        _ input: ProgrammaticInput
    ) {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.nativeView.shouldDeferRuntimeInput = true

        input.send(to: fixture.surface)

        #expect(fixture.nativeView.deferredRuntimeInputs.count == 1)
        #expect(
            fixture.nativeView.deferredRuntimeInputBytes.allSatisfy { $0 > 0 }
        )
        #expect(
            fixture.paneHost.explicitInputCount
                == input.expectedExplicitInputCount
        )
        fixture.nativeView.shouldDeferRuntimeInput = false
        fixture.nativeView.deferredRuntimeInputs.removeFirst()()
        #expect(fixture.nativeView.deferredRuntimeInputs.isEmpty)
        #expect(
            fixture.paneHost.explicitInputCount
                == input.expectedExplicitInputCount
        )
    }

    @Test func parsedInputChecksDeferralBetweenLiveEvents() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }
        fixture.nativeView.runtimeInputDeferralResponses = [false, true, true]

        let result = fixture.surface.sendInputResult("x\r")

        #expect(result == .queued)
        #expect(fixture.nativeView.runtimeInputDeferralCallCount == 3)
        #expect(fixture.nativeView.deferredRuntimeInputs.count == 2)
        #expect(
            fixture.nativeView.deferredRuntimeInputBytes.allSatisfy { $0 > 0 }
        )
    }

    @Test func genericCtrlLetterParserRecognizesPlusAndDashForms() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        for spelling in ["ctrl+p", "ctrl-p", "control+p"] {
            let event = fixture.surface.pendingKeyEvent(for: spelling)
            #expect(event?.keycode == UInt32(kVK_ANSI_P))
            #expect(event?.mods.rawValue == GHOSTTY_MODS_CTRL.rawValue)
        }
        #expect(fixture.surface.pendingKeyEvent(for: "ctrl+1") == nil)
    }

    @Test func syntheticCtrlLetterProvidesGhosttyEncoderTextAndCodepoint() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }
        cmuxTestGhosttySurfaceKeyReset()

        #expect(fixture.surface.sendNamedKey("ctrl+p") == .sent)
        #expect(cmuxTestGhosttySurfaceKeyWasCalled())
        #expect(cmuxTestGhosttySurfaceKeyMods() == Int32(GHOSTTY_MODS_CTRL.rawValue))
        #expect(cmuxTestGhosttySurfaceKeyUnshiftedCodepoint() == UInt32("p".unicodeScalars.first!.value))
        #expect(String(cString: cmuxTestGhosttySurfaceKeyText()) == "p")
    }

    @Test func pasteTextNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendTextResult("hello") == .queued)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func pasteReportsClipboardDeferralAndRetainsOneReplay() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.nativeView.shouldDeferRuntimeInput = true

        #expect(fixture.surface.sendTextResult("literal\n世界") == .queued)
        #expect(fixture.nativeView.deferredRuntimeInputs.count == 1)
        #expect(fixture.surface.pendingSocketInputBytes == 0)

        fixture.nativeView.shouldDeferRuntimeInput = false
        fixture.nativeView.deferredRuntimeInputs.removeFirst()()
        #expect(fixture.surface.pendingSocketInputBytes == "literal\n世界".utf8.count)
    }

    @Test func pasteReportsQueueFullWithoutAcceptingText() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.pendingSocketInputBytes = fixture.surface.maxPendingSocketInputBytes
        var accepted = 0
        fixture.surface.onExplicitInput = { accepted += 1 }

        #expect(fixture.surface.sendTextResult("literal\n世界") == .inputQueueFull)
        #expect(fixture.surface.pendingSocketInputBytes == fixture.surface.maxPendingSocketInputBytes)
        #expect(accepted == 0)
    }

    @Test func pasteReportsClosedSurfaceWithoutQueueing() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.beginPortalCloseLifecycle(reason: "test.closed")

        #expect(fixture.surface.sendTextResult("literal\n世界") == .surfaceUnavailable)
        #expect(fixture.surface.pendingSocketInputBytes == 0)
    }

    @Test func parsedInputNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendInputResult("hello").accepted)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func queuedParsedInputNotifiesItsOwner() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        var acceptedInputCount = 0
        fixture.surface.onExplicitInput = { acceptedInputCount += 1 }

        #expect(fixture.surface.sendInputResult("hello") == .queued)

        #expect(acceptedInputCount == 1)
    }

    @Test func coldSurfaceKeepsQueuedTextAndKeyInSubmissionOrder() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendTextResult("echo ready\n") == .queued)
        #expect(fixture.surface.sendNamedKey("enter") == .queued)

        let pending = fixture.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 2)
        #expect(pending.pasteTextItems == 1)
        #expect(pending.keyEvents == 1)

        let runtimeSurface = allocatedRuntimeSurface()
        fixture.registry.registerRuntimeSurface(runtimeSurface, ownerId: fixture.surface.id)
        fixture.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        cmuxTestGhosttyInputEventsReset()
        fixture.surface.flushPendingSocketInputIfNeeded()

        #expect(cmuxTestGhosttyInputEventCount() == 2)
        #expect(cmuxTestGhosttyInputEventKind(0) == 1, "Expected queued text to replay first")
        #expect(cmuxTestGhosttyInputEventKind(1) == 2, "Expected queued key to replay second")
    }

    @Test func rejectedParsedInputDoesNotNotifyItsOwner() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        var acceptedInputCount = 0
        fixture.surface.onExplicitInput = { acceptedInputCount += 1 }
        fixture.surface.pendingSocketInputBytes = fixture.surface.maxPendingSocketInputBytes

        #expect(fixture.surface.sendInputResult("hello") == .inputQueueFull)

        #expect(fixture.paneHost.explicitInputCount == 1)
        #expect(acceptedInputCount == 0)
    }

    @Test func namedKeyNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendNamedKey("enter").accepted)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func keyTextNotifiesPaneHostBeforeWritingToALiveSurface() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

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

    @Test func losingFocusCancelsKeyboardCopyModeOnTheSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.nativeView.isKeyboardCopyModeActive = true

        fixture.surface.setFocus(true)
        fixture.surface.setFocus(false)

        #expect(fixture.nativeView.keyboardCopyModeCancellationCount == 1)
        #expect(!fixture.nativeView.isKeyboardCopyModeActive)
    }

    @Test func mobileGesturesNotifyPaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        fixture.surface.mobileScroll(deltaLines: 1, col: 0, row: 0)
        fixture.surface.mobileClick(col: 0, row: 0)

        #expect(fixture.paneHost.explicitInputCount == 2)
    }

    @Test func mobileMousePressAndReleaseStayAtomicWhenPressStartsPaste() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }
        fixture.nativeView.runtimeInputDeferralResponses = [false, true]

        fixture.surface.mobileClick(col: 4, row: 7)

        #expect(
            fixture.nativeView.mobileMouseButtonEvents == ["press", "release"]
        )
        #expect(fixture.nativeView.runtimeInputDeferralCallCount == 1)
        #expect(fixture.nativeView.deferredRuntimeInputs.isEmpty)
        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    /// https://github.com/manaflow-ai/cmux/issues/24404: a phone line sent as
    /// a discrete wheel tick is multiplied by `mouse-scroll-multiplier.discrete`
    /// (3 by default) inside libghostty, so an alt-screen program moved three
    /// rows per line. A precision scroll in backing pixels is divided by the
    /// cell height instead, so one line is one row.
    @Test func mobileScrollSendsOneRowPerLineAsAPrecisionScroll() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        cmuxTestGhosttySurfaceSizeSet(14, 32)
        cmuxTestGhosttyMouseScrollReset()
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            cmuxTestGhosttyMouseScrollReset()
            cmuxTestGhosttySurfaceSizeSet(0, 0)
        }

        fixture.surface.mobileScroll(deltaLines: -2, col: 0, row: 0)

        #expect(cmuxTestGhosttyMouseScrollCallCount() == 1)
        #expect(cmuxTestGhosttyMouseScrollLastMods() == 1)
        #expect(cmuxTestGhosttyMouseScrollLastX() == 0)
        #expect(cmuxTestGhosttyMouseScrollLastY() == -2 * 32)
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
        onAttach: (() -> Void)? = nil,
        runtimeSurface: ghostty_surface_t? = nil
    ) -> (
        surface: TerminalSurface,
        paneHost: FakeTerminalSurfacePaneHost,
        nativeView: FakeTerminalSurfaceNativeView,
        registry: FakeSurfaceRegistry
    ) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView, onAttach: onAttach)
        let registry = FakeSurfaceRegistry()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: initialInput,
            preparePaneHost: preparePaneHost,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
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
                    agentCommandShimRootDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        if let runtimeSurface {
            registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
            surface.installRuntimeSurfaceForTesting(runtimeSurface)
        }
        return (surface, paneHost, nativeView, registry)
    }

    private func allocatedRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    }
}
