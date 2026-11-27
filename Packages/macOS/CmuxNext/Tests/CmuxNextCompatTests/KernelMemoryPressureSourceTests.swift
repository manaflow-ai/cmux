import CmuxNextCompat
import Testing

/// A ``KernelMemoryPressureSource`` is safe to release in every state: never started, cancelled
/// before it started, and started then cancelled. libdispatch traps ("Release of an inactive
/// object") when the last reference to a dispatch source that was never activated goes, so a source
/// made eagerly in the init and activated only by ``KernelMemoryPressureSource/start(delivering:)``
/// crashes the process here.
@MainActor @Suite struct KernelMemoryPressureSourceTests {
    @Test func releasingAnUnstartedSourceIsSafe() {
        var source: KernelMemoryPressureSource? = KernelMemoryPressureSource()
        #expect(source != nil)
        source = nil
        #expect(source == nil)
    }

    @Test func releasingASourceCancelledBeforeStartIsSafe() {
        var source: KernelMemoryPressureSource? = KernelMemoryPressureSource()
        source?.cancel()
        source = nil
        #expect(source == nil)
    }

    @Test func releasingAStartedThenCancelledSourceIsSafe() {
        var source: KernelMemoryPressureSource? = KernelMemoryPressureSource()
        source?.start { _ in }
        source?.cancel()
        source = nil
        #expect(source == nil)
    }
}
