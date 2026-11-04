import CmuxNextAgentPane
@testable import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

@Suite(.serialized)
struct SessionExposureTests {
    @Test func stateEventIsStrictAndSurvivesUnrelatedOnlineUpdates() throws {
        let line = #"{"type":"session_exposure_state","available":true,"configured":true,"sessions":["chat-a"],"blocked_sessions":["chat-b"]}"#
        guard case let .sessionExposureState(available, configured, sessions, blocked)? = MobileHostEvent(line: line) else {
            Issue.record("missing session exposure state")
            return
        }
        #expect(available)
        #expect(configured)
        #expect(sessions == ["chat-a"])
        #expect(blocked == ["chat-b"])

        var state = MobileHostState(phase: .connecting)
        state.apply(.sessionExposureState(available: available, configured: configured,
                                          sessions: sessions, blockedSessions: blocked), at: Date())
        state.apply(.online(deviceID: "mac", teamID: "team"), at: Date())
        #expect(state.sessionExposureKnown)
        #expect(state.sessionExposureAvailable)
        #expect(state.exposedSessionIDs == ["chat-a"])
        #expect(state.blockedSessionIDs == ["chat-b"])

        state.apply(.connecting, at: Date())
        #expect(state.sessionExposureKnown)
        #expect(state.sessionExposureAvailable)
        state.apply(.online(deviceID: "mac", teamID: "team"), at: Date())
        #expect(state.sessionExposureKnown)
        #expect(state.sessionExposureAvailable)
        state.apply(.waiting(reason: "reconnect", retryInSeconds: 1), at: Date())
        state.apply(.connecting, at: Date())
        #expect(state.sessionExposureKnown)
        #expect(state.sessionExposureAvailable)

        state.apply(.sessionExposureError(sessionID: "chat-a", allowed: true, reason: "unavailable"), at: Date())
        #expect(state.sessionExposureKnown)
        #expect(!state.sessionExposureAvailable)

        let malformed = #"{"type":"session_exposure_state","configured":true,"sessions":[],"blocked_sessions":[]}"#
        #expect(MobileHostEvent(line: malformed) == nil)
    }

    @Test func configuredPolicyUsesExplicitBlocksAndMasterToggleDoesNotEraseThem() {
        let allowed = IPhoneHostService.remoteControlState(
            signedIn: true, servesPhones: true, allowed: true, sessionID: "chat-a",
            exposureConfigured: true, blockedSessionIDs: ["chat-b"], exposureAvailable: true)
        let blocked = IPhoneHostService.remoteControlState(
            signedIn: true, servesPhones: true, allowed: true, sessionID: "chat-b",
            exposureConfigured: true, blockedSessionIDs: ["chat-b"], exposureAvailable: true)
        #expect(allowed?.on == true)
        #expect(blocked?.on == false)

        let masterOff = IPhoneHostService.remoteControlState(
            signedIn: true, servesPhones: true, allowed: false, sessionID: "chat-b",
            exposureConfigured: true, blockedSessionIDs: ["chat-b"], exposureAvailable: true)
        let masterOnAgain = IPhoneHostService.remoteControlState(
            signedIn: true, servesPhones: true, allowed: true, sessionID: "chat-b",
            exposureConfigured: true, blockedSessionIDs: ["chat-b"], exposureAvailable: true)
        #expect(masterOff?.on == false)
        #expect(masterOnAgain?.on == false)
    }

    @Test func nilProcessRejectsWithoutReportingSuccess() async {
        let supervisor = MobileHostSupervisor()
        await #expect(throws: MobileHostSupervisor.SessionExposureError.hostUnavailable) {
            try await supervisor.setSessionExposure(sessionID: "chat-a", allowed: true)
        }
    }

    @Test func runningHostAcknowledgesExactAllowAndRejectsDurableFailure() async throws {
        let success = try Self.script(mode: "success")
        defer { Self.remove(success) }
        let supervisor = MobileHostSupervisor()
        await supervisor.start(Self.inputs(executable: success))
        await Self.waitForStart(supervisor)
        try await supervisor.setSessionExposure(sessionID: "chat-a", allowed: true)
        await supervisor.stop()

        let failure = try Self.script(mode: "error")
        defer { Self.remove(failure) }
        let rejecting = MobileHostSupervisor()
        await rejecting.start(Self.inputs(executable: failure))
        await Self.waitForStart(rejecting)
        await #expect(throws: MobileHostSupervisor.SessionExposureError.self) {
            try await rejecting.setSessionExposure(sessionID: "chat-a", allowed: false)
        }
        await rejecting.stop()
    }

    @Test func runningHostTimeoutIsNotSuccess() async throws {
        let executable = try Self.script(mode: "timeout")
        defer { Self.remove(executable) }
        let supervisor = MobileHostSupervisor()
        await supervisor.start(Self.inputs(executable: executable))
        await Self.waitForStart(supervisor)
        await #expect(throws: MobileHostSupervisor.SessionExposureError.timedOut) {
            try await supervisor.setSessionExposure(sessionID: "chat-a", allowed: true)
        }
        await supervisor.stop()
    }

    private static func inputs(executable: URL) -> MobileHostSupervisor.Inputs {
        let launch = MobileHostLaunch(executable: executable, baseURL: URL(string: "https://example.invalid")!,
                                      teamID: "team", userID: "user", deviceID: "device", deviceName: "Mac",
                                      daemonSocket: "/tmp/cmux-test.sock", stateDirectory: URL(fileURLWithPath: "/tmp"),
                                      fileRoots: [], stackProjectID: "project")
        return .init(launch: launch, accessToken: { _ in "token" }, acpmux: { nil }, log: nil,
                     inherited: ["HOME": "/tmp", "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp"])
    }

    private static func waitForStart(_ supervisor: MobileHostSupervisor) async {
        for await state in supervisor.states {
            if case .connecting = state.phase { return }
        }
    }

    private static func script(mode: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/cmux-session-exposure-\(UUID().uuidString).sh")
        let body = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *session_exposure*)
              if [ "\(mode)" = "success" ]; then
                printf '%s\\n' '{"type":"session_exposure_state","available":true,"configured":true,"sessions":["chat-a"],"blocked_sessions":[]}'
              elif [ "\(mode)" = "error" ]; then
                printf '%s\\n' '{"type":"session_exposure_error","session_id":"chat-a","allowed":false,"reason":"durable policy unavailable"}'
              fi
              ;;
          esac
        done
        """
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
