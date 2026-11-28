import AppKit
import Testing
@testable import MessagesLabHome

/// Home's render-scale scope runs on the main thread from AppKit callbacks (a layer's draw, a
/// window move), where no Swift task is current. A task local bound there lives in the thread's
/// fallback storage, and an isolated deinit that runs inline under it (every main-actor class of a
/// main-actor-default target has one) makes the macOS 15.4 to 15.x runtime pop its stop-lookup
/// marker with `free()`: a pointer malloc never returned, which Chromium's allocator traps on
/// (CMUXTERM-MACOS-44XN, macOS 15.8.1, Cmd-1 leaving Home; macOS 15 tester, "crashes after cmd 123").
/// The scope must give the scale without binding a task local there.
@MainActor @Suite(.serialized) struct RenderScaleScopeTests {
    /// Runs `body` as an AppKit callback does: a main-thread block with no Swift task.
    private func onMainOutsideATask<T: Sendable>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            // concurrency-allow: the test needs a main-thread block outside any Swift task, as AppKit runs one
            DispatchQueue.main.async {
                #expect(!withUnsafeCurrentTask { $0 != nil })
                continuation.resume(returning: MainActor.assumeIsolated(body))
            }
        }
    }

    @Test func aScopeOnTheMainThreadOutsideATaskBindsNoTaskLocal() async {
        let (scale, bound) = await onMainOutsideATask { () -> (CGFloat, CGFloat?) in
            Fixture.withRenderScale(3) { (Fixture.renderScale, RenderScaleScope.$scoped.get()) }
        }
        #expect(scale == 3)
        #expect(bound == nil)
    }

    @Test func nestedScopesRestoreTheOuterScale() async {
        let seen = await onMainOutsideATask { () -> [CGFloat] in
            Fixture.withRenderScale(3) {
                let inner = Fixture.withRenderScale(1) { DisplayScale.current }
                return [Fixture.renderScale, inner, DisplayScale.current]
            }
        }
        #expect(seen == [3, 1, 3])
    }

    /// Inside a task (the scope's work in an async context) the scale still follows the scope.
    @Test func aScopeInsideATaskGivesItsScale() {
        #expect(Fixture.withRenderScale(3) { Fixture.renderScale } == 3)
    }
}
