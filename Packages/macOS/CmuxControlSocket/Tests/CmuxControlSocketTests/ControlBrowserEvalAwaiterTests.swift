import Dispatch
import Foundation
import Testing
@testable import CmuxControlSocket

/// Behavior coverage for ``ControlBrowserEvalAwaiter``, the bounded blocking
/// primitive the worker-lane browser JS-eval core blocks on. Exercised off the
/// main thread (the socket-worker lane it runs on in production) so the
/// `DispatchSemaphore` branch is the one under test, matching the legacy
/// `v2AwaitCallback` off-main path.
@Suite(.serialized)
struct ControlBrowserEvalAwaiterTests {
    /// A callback delivered before the timeout returns its value.
    @Test
    func deliversValueBeforeTimeout() async {
        let value: Int? = await Task.detached {
            ControlBrowserEvalAwaiter().await(timeout: 2.0) { finish in
                DispatchQueue.global().async {
                    finish(42)
                }
            }
        }.value
        #expect(value == 42)
    }

    /// A callback that never fires returns `nil` once the timeout elapses.
    @Test
    func returnsNilOnTimeout() async {
        let value: Int? = await Task.detached {
            ControlBrowserEvalAwaiter().await(timeout: 0.05) { _ in
                // Never call finish: the awaiter must time out.
            }
        }.value
        #expect(value == nil)
    }

    /// A callback delivered after the timeout has already returned `nil` is
    /// discarded and does not crash (idempotent, late `finish`).
    @Test
    func ignoresLateCallbackAfterTimeout() async {
        let value: Int? = await Task.detached {
            ControlBrowserEvalAwaiter().await(timeout: 0.05) { finish in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    finish(7)
                }
            }
        }.value
        #expect(value == nil)
    }
}
