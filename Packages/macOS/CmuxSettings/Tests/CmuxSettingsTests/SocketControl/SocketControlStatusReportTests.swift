import CmuxSettings
import Foundation
import Testing

/// Behavior tests for ``SocketControlStatusReport``, the payload `cmux socket
/// status` prints. An administrator reads it to confirm the policy landed on a
/// host, so it must report the mode the listener actually runs, the mode the
/// user asked for, and which of the two is in force.
struct SocketControlStatusReportTests {
    private func makeReport(
        configuredMode: SocketControlMode = .cmuxOnly,
        policy: SocketControlModePolicy = SocketControlModePolicy(forcedRawValue: nil),
        environment: [String: String] = [:]
    ) -> SocketControlStatusReport {
        SocketControlStatusReport(
            configuredMode: configuredMode,
            policy: policy,
            environment: environment,
            domain: "com.cmuxterm.app",
            socketPath: "/tmp/cmux.sock"
        )
    }

    @Test func anUnmanagedMacReportsTheUsersOwnMode() {
        let report = makeReport(configuredMode: .allowAll)

        #expect(report.configuredMode == .allowAll)
        #expect(report.effectiveMode == .allowAll)
        #expect(!report.isManaged)
        #expect(report.summary == "allowAll")
    }

    @Test func aManagedMacReportsTheForcedModeAndKeepsTheUsersOwnVisible() {
        let report = makeReport(
            configuredMode: .allowAll,
            policy: SocketControlModePolicy(forcedRawValue: "cmuxonly")
        )

        #expect(report.configuredMode == .allowAll)
        #expect(report.effectiveMode == .cmuxOnly)
        #expect(report.isManaged)
        #expect(report.summary == "cmuxOnly (managed)")
    }

    @Test func anEnvironmentOverrideCannotWidenAManagedMode() {
        let report = makeReport(
            configuredMode: .cmuxOnly,
            policy: SocketControlModePolicy(forcedRawValue: "cmuxonly"),
            environment: ["CMUX_SOCKET_MODE": "allowall"]
        )

        #expect(report.effectiveMode == .cmuxOnly)
        #expect(report.isManaged)
    }

    @Test func anEnvironmentOverrideStillAppliesWithoutAProfile() {
        let report = makeReport(
            configuredMode: .cmuxOnly,
            environment: ["CMUX_SOCKET_MODE": "allowall"]
        )

        #expect(report.effectiveMode == .allowAll)
        #expect(!report.isManaged)
    }

    @Test func theJSONPayloadCarriesEveryFieldAFleetCheckNeeds() throws {
        let report = makeReport(
            configuredMode: .allowAll,
            policy: SocketControlModePolicy(forcedRawValue: "off")
        )
        let payload = report.jsonObject

        #expect(payload["mode"] as? String == SocketControlMode.off.rawValue)
        #expect(payload["configured_mode"] as? String == SocketControlMode.allowAll.rawValue)
        #expect(payload["managed"] as? Bool == true)
        #expect(payload["source"] as? String == "managed")
        #expect(payload["domain"] as? String == "com.cmuxterm.app")
        #expect(payload["key"] as? String == "SocketControlMode")
        #expect(payload["socket_path"] as? String == "/tmp/cmux.sock")
        // The payload must survive JSON serialization; a value of a type
        // JSONSerialization rejects would make the command fail on a host.
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test func anUnmanagedPayloadNamesTheUserAsTheSource() {
        let payload = makeReport(configuredMode: .password).jsonObject

        #expect(payload["managed"] as? Bool == false)
        #expect(payload["source"] as? String == "user")
        #expect(payload["mode"] as? String == SocketControlMode.password.rawValue)
    }
}
