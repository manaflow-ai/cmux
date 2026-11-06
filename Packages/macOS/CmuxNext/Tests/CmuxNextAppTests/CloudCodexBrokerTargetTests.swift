import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud Codex broker target")
struct CloudCodexBrokerTargetTests {
    @Test func readsPrettyPrintedRunningDaemonCapabilities() {
        let output = "{\n  \"capabilities\": [\n    \"codex-external-access-v1\"\n  ]\n}"
        #expect(CloudCodexBrokerTarget.supportsExternalAccess(output))
        #expect(!CloudCodexBrokerTarget.supportsExternalAccess("{\"capabilities\":[]}"))
    }

    /// A machine the caller does not own is refused before anything runs on it.
    @Test func aMachineTheCallerDoesNotOwnIsRefusedBeforeGuestExecution() async throws {
        let cmux = try Self.cmux(supported: true)
        defer { cmux.remove() }
        let capability = try await target(cmux, owns: { false }).capability()
        #expect(capability == .init(ownerVM: false, protocolVersion: 0, codexExternalAccessToken: false))
        #expect(cmux.runs == 0, "Non-owner must be rejected before guest execution")
    }

    @Test func authoritativeOwnerStillRequiresRunningBridgeCapability() async throws {
        let owner = try Self.cmux(supported: true)
        defer { owner.remove() }
        let ready = try await target(owner, owns: { true }).capability()
        #expect(ready == .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true))
        // The exec goes to the pinned team, never the app's current one.
        #expect(owner.request(1)["team"] as? String == "pinned-team")
        #expect(owner.calls == ["machine.io exec"])
        let unsupported = try Self.cmux(supported: false)
        defer { unsupported.remove() }
        let old = try await target(unsupported, owns: { true }).capability()
        #expect(old == .init(ownerVM: true, protocolVersion: 0, codexExternalAccessToken: false))
    }

    /// An owner answer that fails fails the capability: it never falls back to guest files.
    @Test func ownershipFailuresNeverFallBackToGuestFiles() async throws {
        struct Refused: Error {}
        let cmux = try Self.cmux(supported: true)
        defer { cmux.remove() }
        await #expect(throws: (any Error).self) {
            _ = try await target(cmux, owns: { throw Refused() }).capability()
        }
        #expect(cmux.runs == 0)
    }

    /// A stand-in cmux whose exec answers the daemon's capabilities, with or without the broker's.
    private static func cmux(supported: Bool) throws -> FakeBundledCmux {
        let stdout = supported ? #"{\"capabilities\":[\"codex-external-access-v1\"]}"# : #"{\"capabilities\":[]}"#
        return try FakeBundledCmux(answer: #"{"ok":true,"body":{"exitCode":0,"stdout":"\#(stdout)","stderr":""}}"#)
    }

    private func target(_ cmux: FakeBundledCmux, owns: @escaping @Sendable () async throws -> Bool) -> CloudCodexBrokerTarget {
        CloudCodexBrokerTarget(api: cmux.classic(team: "different-team"), machineID: "vm-1",
                               scope: .init(userID: "user-1", teamID: "pinned-team"), callerOwnsVM: owns, isLive: { true })
    }
}
