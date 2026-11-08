#if os(iOS)
/// Tests that drive a whole terminal screen (`TerminalViewController`) take
/// turns, across suites: the bench probe (`TerminalBenchProbe.shared`) counts
/// the output of every screen alive, so another suite's screen running beside
/// `TerminalBenchProbeAccountingTests` showed up in its byte count.
///
///     await TerminalScreenTestLock.acquire()
///     defer { TerminalScreenTestLock.release() }
@MainActor
enum TerminalScreenTestLock {
    private static var held = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        while held {
            await withCheckedContinuation { waiting.append($0) }
        }
        held = true
    }

    static func release() {
        held = false
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }
}
#endif
