import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_realized_begin")
private func beginRendererRealizedTracking(_ surface: UnsafeMutableRawPointer)

@_silgen_name("cmux_test_ghostty_renderer_realized_reset")
private func resetRendererRealizedTracking()

@_silgen_name("cmux_test_ghostty_renderer_realized_call_count")
private func rendererRealizedCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_renderer_realized_call_value")
private func rendererRealizedCallValue(_ index: UInt32) -> Bool

@_silgen_name("cmux_test_ghostty_renderer_realized_set_result")
private func setRendererRealizedResult(_ result: Bool)

@_silgen_name("cmux_test_ghostty_renderer_release_was_occluded")
private func rendererReleaseWasOccluded() -> Bool

@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererPresentationTests {
    @Test func alacrittyHiddenRuntimeReleasesRendererAndRestoresItWhenShown() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry, backend: .alacritty)
        let runtime = FakeAlacrittyTerminalRuntime()
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.alacrittyRuntime = runtime
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)

        #expect(!surface.isRendererRealized)
        #expect(runtime.rendererRealizationRequests == [false])

        surface.setRendererPortalVisible(true, attachmentReady: true)

        #expect(surface.isRendererRealized)
        #expect(surface.isRendererPresented)
        #expect(runtime.rendererRealizationRequests == [false, true])
    }

    @Test func firstPresentationWaitsUntilTheSurfaceIsAttachedToARealWindow() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: false)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        #expect(rendererRealizedCalls() == [false])

        surface.setRendererPortalVisible(true, attachmentReady: false)

        #expect(surface.isRendererPortalVisible)
        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false])

        surface.ensureRendererPresented(attachmentReady: true)

        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false, true])
    }

    @Test func hiddenRuntimeIsReleasedThenRealizedOnFirstVisibility() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        #expect(!surface.isRendererRealized)
        #expect(rendererRealizedCalls() == [false])

        surface.setRendererPortalVisible(true, attachmentReady: true)

        #expect(surface.isRendererPortalVisible)
        #expect(surface.isRendererRealized)
        #expect(rendererRealizedCalls() == [false, true])

        surface.setRendererPortalVisible(true, attachmentReady: true)

        #expect(rendererRealizedCalls() == [false, true])
    }

    @Test func hiddenRuntimeIsOccludedBeforeRendererRelease() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        #expect(rendererRealizedCalls() == [false])
        #expect(rendererReleaseWasOccluded())
    }

    @Test func visibleRuntimeIsPresentedWithoutRedundantNativeTransition() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(true, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        #expect(surface.isRendererPortalVisible)
        #expect(surface.isRendererRealized)
        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls().isEmpty)

        surface.setRendererPortalVisible(true, attachmentReady: true)

        #expect(rendererRealizedCalls().isEmpty)
    }

    @Test func reclaimedRuntimeIsRealizedOnceWhenShownAgain() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(true, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        surface.setRendererPortalVisible(false, attachmentReady: true)

        #expect(surface.releaseRenderer())
        #expect(!surface.isRendererRealized)
        #expect(rendererRealizedCalls() == [false])

        surface.setRendererPortalVisible(true, attachmentReady: true)
        surface.setRendererPortalVisible(true, attachmentReady: true)

        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false, true])
    }

    @Test func failedFirstPresentationWaitsForRendererActivityBeforeSchedulingRepair() {
        let registry = TerminalSurfaceRegistry()
        let scheduler = FakeRendererRealizationScheduler()
        let surface = makeSurface(registry: registry, rendererRealization: scheduler)
        let callbackContext = installRendererCallbackContext(on: surface, scheduler: scheduler)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        surface.setRendererPortalVisible(true, attachmentReady: true)

        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false])
        #expect(scheduler.scheduledSurfaceIDs.isEmpty)

        setRendererRealizedResult(true)
        scheduler.onSchedule = { surfaceID in
            #expect(surfaceID == surface.id)
            surface.retryRendererPresentationAfterActivity(attachmentReady: true)
        }
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_DRAW_FRAME_END
        )
        #expect(scheduler.scheduledSurfaceIDs.isEmpty)
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END
        )
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END
        )

        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false, false, true])
        #expect(scheduler.scheduledSurfaceIDs == [surface.id])
    }

    @Test func laterRendererActivityRepairsAfterRepeatedMailboxFailures() {
        let registry = TerminalSurfaceRegistry()
        let scheduler = FakeRendererRealizationScheduler()
        let surface = makeSurface(registry: registry, rendererRealization: scheduler)
        let callbackContext = installRendererCallbackContext(on: surface, scheduler: scheduler)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        scheduler.onSchedule = { surfaceID in
            #expect(surfaceID == surface.id)
            surface.retryRendererPresentationAfterActivity(attachmentReady: true)
        }
        surface.setRendererPortalVisible(true, attachmentReady: true)
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END
        )

        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [true, true])
        #expect(scheduler.scheduledSurfaceIDs == [surface.id])

        setRendererRealizedResult(true)
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END
        )

        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [true, true, true])
        #expect(scheduler.scheduledSurfaceIDs == [surface.id, surface.id])
    }

    @Test func rendererActivityDoesNotRetryAfterSurfaceBecomesHidden() {
        let registry = TerminalSurfaceRegistry()
        let scheduler = FakeRendererRealizationScheduler()
        let surface = makeSurface(registry: registry, rendererRealization: scheduler)
        let callbackContext = installRendererCallbackContext(on: surface, scheduler: scheduler)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        surface.setRendererPortalVisible(true, attachmentReady: true)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        callbackContext.takeUnretainedValue().rendererMailboxDidDrain()
        surface.retryRendererPresentationAfterActivity(attachmentReady: true)

        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [true])
        #expect(scheduler.scheduledSurfaceIDs.isEmpty)
    }

    @Test func queuedRendererRepairDoesNotTouchReleasedSurface() {
        let registry = TerminalSurfaceRegistry()
        let scheduler = FakeRendererRealizationScheduler()
        let surface = makeSurface(registry: registry, rendererRealization: scheduler)
        let callbackContext = installRendererCallbackContext(on: surface, scheduler: scheduler)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false, attachmentReady: true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate(attachmentReady: true)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        var queuedRepair: (() -> Void)?
        scheduler.onSchedule = { surfaceID in
            #expect(surfaceID == surface.id)
            queuedRepair = {
                surface.retryRendererPresentationAfterActivity(attachmentReady: true)
            }
        }
        surface.setRendererPortalVisible(true, attachmentReady: true)
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END
        )

        #expect(scheduler.scheduledSurfaceIDs == [surface.id])
        #expect(rendererRealizedCalls() == [true])

        surface.releaseSurfaceForTesting()
        queuedRepair?()

        #expect(!surface.hasLiveSurface)
        #expect(rendererRealizedCalls() == [true])
    }

    private func rendererRealizedCalls() -> [Bool] {
        (0..<rendererRealizedCallCount()).map(rendererRealizedCallValue)
    }

    private func installRendererCallbackContext(
        on surface: TerminalSurface,
        scheduler: FakeRendererRealizationScheduler
    ) -> Unmanaged<GhosttySurfaceCallbackContext> {
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: surface.surfaceView,
            surfaceController: surface,
            rendererMailboxDidDrain: { surfaceID in
                MainActor.assumeIsolated {
                    scheduler.scheduleRendererPresentationRepair(surfaceID: surfaceID)
                }
            }
        ))
        surface.surfaceCallbackContext = callbackContext
        return callbackContext
    }

    private func makeSurface(
        registry: TerminalSurfaceRegistry,
        backend: TerminalRuntimeBackend = .ghostty,
        rendererRealization: any TerminalRendererRealizationScheduling = FakeRendererRealizationScheduler()
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
                engine: FakeTerminalEngine(),
                backend: backend,
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: rendererRealization,
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
    }

}

private final class FakeAlacrittyTerminalRuntime: AlacrittyTerminalRuntimeProtocol {
    private(set) var rendererRealizationRequests: [Bool] = []
    private var rendererRealized = true

    func setRendererRealized(_ realized: Bool) -> Bool {
        rendererRealizationRequests.append(realized)
        rendererRealized = realized
        return true
    }

    var isRendererRealized: Bool { rendererRealized }

    func updateAppearance(_: TerminalRuntimeAppearance) -> Bool { true }
    func close() {}
    func draw() -> Bool { rendererRealized }
    func resize(widthPixels _: UInt32, heightPixels _: UInt32, scaleFactor _: CGFloat) -> Bool {
        true
    }
    func write(_: Data) -> Bool { true }
    func sendKey(_: AlacrittyTerminalKey, modifiers _: AlacrittyTerminalModifiers) -> Bool { true }
    func scroll(lines _: Int32) -> Bool { true }
    func setFocus(_: Bool) -> Bool { true }
    func screenText(includeScrollback _: Bool) -> String? { "" }
    var processExited: Bool { false }
    var needsConfirmClose: Bool { false }
    var childPID: UInt32 { 1 }
    func gridSize() -> (
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    )? {
        (80, 24, 8, 16)
    }
}
