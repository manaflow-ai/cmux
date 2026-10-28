import CmuxNextCompat
import CmuxNextIcons
import CmuxNextLaunch
import Foundation
import Testing

/// The icon pack and catalog (367 KB of JSON, a `swift_once` each) decode on the
/// launch's icon warm-up thread, not on main at the first tab or sidebar icon before the first frame.
/// The decode and the launch-mark sink are injected: the process-wide icon globals may already be
/// decoded by another suite, so reading them here would prove nothing about where the decode ran.
@MainActor @Suite("Launch icon warm-up")
struct LaunchIconWarmupTests {
    private nonisolated enum Event: Equatable, Sendable {
        case decode(onMain: Bool, thread: String?)
        case decoded(onMain: Bool, thread: String?)
        case startedIconDecode
        case marked(String)
    }

    private nonisolated final class Log: Sendable {
        private let events = Mutex<[Event]>([])
        private let completion = Mutex<(@Sendable () -> Void)?>(nil)

        var recorded: [Event] { events.withLock { $0 } }

        func record(_ event: Event) {
            events.withLock { $0.append(event) }
        }

        /// Keeps a decode's completion so the test chooses when the decode ends.
        func hold(_ decoded: @escaping @Sendable () -> Void) {
            completion.withLock { $0 = decoded }
        }

        func finishHeldDecode() {
            completion.withLock { $0 }?()
        }
    }

    @Test("The icon warm-up runs the decode once on its own thread, then the completion after it")
    func decodesOnceOffMainThenCompletes() async {
        let log = Log()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            IconPack.decodeInBackground({
                log.record(.decode(onMain: Thread.isMainThread, thread: Thread.current.name))
            }, then: {
                log.record(.decoded(onMain: Thread.isMainThread, thread: Thread.current.name))
                continuation.resume()
            })
        }
        let warmUp = "cmux-next icon warm-up"
        #expect(log.recorded == [.decode(onMain: false, thread: warmUp), .decoded(onMain: false, thread: warmUp)])
    }

    @Test("Launch warm-up starts the icon decode and marks icons_decoded when it ends")
    func launchStartsIconDecodeAndMarksIt() {
        let log = Log()
        // No warm-up work (the App's catalog build marks only when it claims the build): only the icon mark is seen.
        LaunchWarmup(
            work: {},
            decodeIcons: { decoded in
                log.record(.startedIconDecode)
                log.hold(decoded)
            },
            markLaunch: { log.record(.marked($0)) }
        ).start()
        // Not marked before the decode ends.
        #expect(log.recorded == [.startedIconDecode])
        log.finishHeldDecode()
        #expect(log.recorded == [.startedIconDecode, .marked("icons_decoded")])
    }
}
