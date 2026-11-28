import Testing

struct TraitShorthandIsolationTests {
    @Test func liveDaemonCanBeReadFromNonisolatedCode() {
        #expect(makeLiveDaemonGate().isRecursive)
    }
}

private nonisolated func makeLiveDaemonGate() -> LiveDaemonGate {
    .liveDaemon
}
