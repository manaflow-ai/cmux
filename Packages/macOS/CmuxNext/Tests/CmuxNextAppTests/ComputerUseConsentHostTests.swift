import CmuxNextAgentActivity
import Foundation
import Testing
@testable import CmuxNextComputerUse

/// The app's machine-consent connection to the legacy helper.
struct ComputerUseConsentHostTests {
    @Test func theAttachIsAnAuthenticatedHostRequest() throws {
        let configuration = AgentActivitySocketSource.Configuration(socketPath: "/tmp/h.sock", authToken: "agent",
                                                                    hostAuthToken: "host", machineName: "")
        let line = ComputerUseConsentHost.attachLine(configuration)
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["auth_token"] as? String == "agent")
        #expect(object["host_auth_token"] as? String == "host")
        let request = try #require(object["request"] as? [String: Any])
        #expect(request["method"] as? String == "machine_consent_host")
    }

    @Test func linesAreClassified() {
        #expect(ComputerUseConsentHost.classify(["ok": true, "result": ["attached": true]]) == .attached)
        #expect(ComputerUseConsentHost.classify(["ok": false, "error": "unknown method"]) == .refusedAttach)
        #expect(ComputerUseConsentHost.classify(["type": "machine_consent", "id": 1]) == .question)
        #expect(ComputerUseConsentHost.classify(["type": "consent_refused", "surface": "screen"]) == .question)
        #expect(ComputerUseConsentHost.classify(["type": "event"]) == .other)
    }
}
