import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

/// Readiness follows native presentation receipts rather than a particular CALayer subclass.
@MainActor
@Suite(.serialized)
struct TerminalSurfaceFramePresentationTests {
    @Test
    func waiterRequiresAFrameRequestedAfterItStarted() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let old = fixture.surface.rendererPresentationState.token
        let (task, token) = try await requestFrame(on: fixture.surface)
        fixture.surface.rendererFrameDidPresent(token: old)
        #expect(fixture.surface.rendererPresentationState.inFlightToken == token)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(await task.value == token)
    }

    @Test
    func laterWaitersCannotConsumeAnAlreadyRequestedFrame() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (first, firstToken) = try await requestFrame(on: fixture.surface)
        let second = Task { @MainActor in await fixture.surface.waitForPresentedFrame() }
        let third = Task { @MainActor in await fixture.surface.waitForPresentedFrame() }
        try await waitUntil { fixture.surface.rendererPresentationState.queuedFrameWaiters.count == 2 }
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(await first.value == firstToken)
        let nextToken = try #require(fixture.surface.rendererPresentationState.inFlightToken)
        #expect(nextToken > firstToken)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(await second.value == nextToken)
        #expect(await third.value == nextToken)
    }

    @Test
    func cancellationRetiresOnlyItsOwnWaiter() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (first, _) = try await requestFrame(on: fixture.surface)
        let second = Task { @MainActor in await fixture.surface.waitForPresentedFrame() }
        try await waitUntil { !fixture.surface.rendererPresentationState.queuedFrameWaiters.isEmpty }
        first.cancel()
        #expect(await first.value == nil)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        let token = try #require(fixture.surface.rendererPresentationState.inFlightToken)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(await second.value == token)
    }

    @Test(arguments: [false, true])
    func hidingThePortalOrWindowEndsTheWait(window: Bool) async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (task, _) = try await requestFrame(on: fixture.surface)
        if window { fixture.surface.setRendererWindowVisible(false) }
        else { fixture.surface.setRendererPortalVisible(false, presentationReady: true) }
        #expect(await task.value == nil)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        if window { fixture.surface.setRendererWindowVisible(true) }
        else { fixture.surface.setRendererPortalVisible(true, presentationReady: true) }
        if fixture.surface.rendererPresentationState.inFlightToken != nil {
            #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        }
        let (revealed, token) = try await requestFrame(on: fixture.surface)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(await revealed.value == token)
    }

    @Test
    func aNativeFailureEndsTheWait() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (task, _) = try await requestFrame(on: fixture.surface)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface, Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
        #expect(await task.value == nil)
    }

    @Test
    func anAlreadyHiddenSurfaceDoesNotRequestAFrame() async {
        let fixture = makeFixture(windowVisible: false)
        defer { fixture.tearDown() }
        let before = fixture.surface.rendererPresentationState.token
        #expect(await fixture.surface.waitForPresentedFrame() == nil)
        #expect(fixture.surface.rendererPresentationState.token == before)
    }

    private func requestFrame(on surface: TerminalSurface) async throws -> (Task<UInt64?, Never>, UInt64) {
        let previous = surface.rendererPresentationState.token
        let task = Task { @MainActor in await surface.waitForPresentedFrame() }
        try await waitUntil { surface.rendererPresentationState.token > previous }
        return (task, try #require(surface.rendererPresentationState.inFlightToken))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    private func makeFixture(windowVisible: Bool = true) -> PresentedSurfaceFixture {
        let fixture = PresentedSurfaceFixture(windowVisibleAtCreation: windowVisible)
        let surface = fixture.surface
        let target = TerminalSurfaceCallbackTarget(surface: surface)
        let context = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: surface.surfaceView, surfaceController: surface,
            terminalLifecycleID: surface.terminalLifecycleId,
            rendererFramePresented: { _, token in
                MainActor.assumeIsolated { target.surface?.rendererFrameDidPresent(token: token) }
            },
            rendererFrameFailed: { _, token, status in
                MainActor.assumeIsolated { target.surface?.rendererFrameDidFail(token: token, status: status) }
            }
        ))
        surface.surfaceCallbackContext?.release()
        surface.surfaceCallbackContext = context
        #expect(ghostty_surface_set_render_presented_callback(fixture.runtimeSurface, terminalRendererPresentedCallback, context.toOpaque()))
        #expect(ghostty_surface_set_render_failed_callback(fixture.runtimeSurface, terminalRendererFailedCallback, context.toOpaque()))
        surface.rendererRuntimeSurfaceDidCreate(presentationReady: true)
        if windowVisible { #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface)) }
        return fixture
    }
}
