import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

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

    @Test func queuedParsedInputNotifiesItsOwner() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        var acceptedInputCount = 0
        fixture.surface.onExplicitInput = { acceptedInputCount += 1 }

        #expect(fixture.surface.sendInputResult("hello") == .queued)

        #expect(acceptedInputCount == 1)
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
        nativeView: FakeTerminalSurfaceNativeView
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
                    agentCommandShimTemporaryDirectory: URL(
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
        return (surface, paneHost, nativeView)
    }

    private func allocatedRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    }
}
