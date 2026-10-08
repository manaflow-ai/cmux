@testable import CmuxNextApp
import Testing

/// Session qualifiers read like the machine (plans/cmux-next/data-model.md
/// 1.1, 1.3): the host's first DNS label, plus a non-default session name.
@Suite @MainActor struct ControlSessionsTests {
    @Test func qualifierNamesUseTheShortHostAndTheSession() {
        #expect(ControlSessions.qualifierName(machine: "cmux-dev-backend-1.us-central1-b.c.example.internal", session: "fedtest")
            == "cmux-dev-backend-1-fedtest")
        #expect(ControlSessions.qualifierName(machine: "build-box.local", session: "main") == "build-box")
        #expect(ControlSessions.qualifierName(machine: "10.0.0.7", session: "main") == "10.0.0.7")
        // An SSH label already names its session.
        #expect(ControlSessions.qualifierName(machine: "localhost/ci", session: "ci") == "localhost/ci")
        #expect(ControlSessions.qualifierName(machine: nil, session: "ci") == "ci")
    }
}
