import CmuxNextTestSupport
import Testing

struct TraitShorthandIsolationTests {
    @Test func closesItsWindowsCanBeReadFromNonisolatedCode() {
        #expect(makeWindowLeakCheck().isRecursive == false)
    }

    @Test func ghosttyOverridesCanBeReadFromNonisolatedCode() {
        #expect(makeGhosttyOverridesGate().isRecursive)
    }
}

private nonisolated func makeWindowLeakCheck() -> WindowLeakCheck {
    .closesItsWindows
}

private nonisolated func makeGhosttyOverridesGate() -> GhosttyOverridesGate {
    .ghosttyOverrides
}
