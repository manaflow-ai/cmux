@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// A method that measures over an interval (`resources`: two samples one
/// interval apart) sets its own fixed deadline instead of the 2 s
/// control-plane one; other methods keep the default.
@Suite(.timeLimit(.minutes(1))) struct FixedDeadlineTests {
    // wakeup-allow: test stand-in for a method that measures over an interval
    private static func slow(_ duration: Duration) async { try? await Task.sleep(for: duration) }

    @Test func aFixedDeadlineReplacesTheDefault() async {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(),
                                   configuration: .init(requestDeadline: .milliseconds(50)))
        router.register([
            .async("measure") { _ in
                await Self.slow(.milliseconds(200))
                return .bool(true)
            }.withDeadline(.fixed(.seconds(5))),
            .async("plain") { _ in
                await Self.slow(.milliseconds(200))
                return .bool(true)
            },
        ])
        let measured = await router.handle(ControlRequest(id: "1", method: "measure", params: [:]))
        #expect((try? measured.get()) == .bool(true))
        let plain = await router.handle(ControlRequest(id: "2", method: "plain", params: [:]))
        if case .failure(let error) = plain {
            #expect(error.code == "timeout")
        } else {
            Issue.record("the default deadline did not apply")
        }
    }
}
