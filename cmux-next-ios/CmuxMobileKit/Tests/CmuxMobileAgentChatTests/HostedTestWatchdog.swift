#if os(iOS)
import Foundation
import Testing

/// Ends the test process when the main thread stops answering for 45 s, naming the test that held
/// it, so a hosted test that spins the main thread fails the run at once with its name instead of
/// hanging it until the step is killed with no result (#47189 r7 tip af27658b: the kit tests ran
/// about 40 min, killed, no evidence). A test that only waits too long fails by its suite's time
/// limit instead; this catches the main thread itself busy, which a time limit cannot interrupt.
enum HostedTestWatchdog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastBeat = Date()
    nonisolated(unsafe) private static var test = "?"
    private static let started: Void = {
        let queue = DispatchQueue(label: "hosted-test-watchdog")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            DispatchQueue.main.async {
                let name = Test.current?.name ?? "?"
                lock.withLock { lastBeat = Date(); test = name }
            }
            let (beat, name) = lock.withLock { (lastBeat, test) }
            if Date().timeIntervalSince(beat) > 45 {
                FileHandle.standardError.write(Data("HOSTED_TEST_WATCHDOG: the main thread did not answer for 45 s in test \(name)\n".utf8))
                fatalError("HOSTED_TEST_WATCHDOG: main thread blocked 45 s in \(name)")
            }
        }
        timer.resume()
        keep = timer
    }()
    nonisolated(unsafe) private static var keep: DispatchSourceTimer?

    /// Starts the watchdog (once per process).
    static func start() { _ = started }
}
#endif
