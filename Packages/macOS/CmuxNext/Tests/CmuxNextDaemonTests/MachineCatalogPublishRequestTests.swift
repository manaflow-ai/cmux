import Foundation
import Testing
@testable import CmuxNextDaemon

struct MachineCatalogPublishRequestTests {
    private let owner: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let remote: ResourceID = "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    @Test func oldOwnersReceiveNoPublicationEncodingAdmission() {
        for capabilities in [[], ["agent-cli-app-provider-v1"], ["machine-catalog-publish-v10"]] {
            do {
                try MachineCatalogPublishRequest.requireServed(by: DaemonIdentity(capabilities: capabilities, generation: "boot"))
                Issue.record("unnegotiated publication admitted")
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(missing == ["machine-catalog-publish-v1"])
            } catch { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test func publicationCarriesOnlyFencedOwnerMetadata() throws {
        try MachineCatalogPublishRequest.requireServed(by: DaemonIdentity(capabilities: ["machine-catalog-publish-v1"], generation: "boot"))
        let record = try #require(MachineCatalogRecord(id: remote, name: "server", origin: .ssh, status: .running,
            platform: .init(os: "linux", arch: "aarch64"), capabilities: ["terminal", "agent_session"]))
        let request = MachineCatalogPublishRequest(expectedMachineID: owner, sequence: 7, machines: [record])
        let value = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 19))
        #expect(value == .object([
            "cmd": .string("machine-catalog-publish"), "id": .number(19),
            "expected_machine_id": .string(owner.rawValue), "sequence": .number(7),
            "machines": .array([.object([
                "id": .string(remote.rawValue), "name": .string("server"), "origin": .string("ssh"), "status": .string("running"),
                "platform": .object(["os": .string("linux"), "arch": .string("aarch64")]),
                "capabilities": .array([.string("terminal"), .string("agent_session")]),
            ])]),
        ]))
    }

    @Test func invalidIDsAndUnprovenMetadataCannotBecomeCatalogClaims() throws {
        for id in ["local", "current", "server-name", "machine_" + String(repeating: "A", count: 32)] {
            #expect(MachineCatalogRecord(id: ResourceID(rawValue: id), name: "server", origin: .ssh, status: .running) == nil)
        }
        let record = try #require(MachineCatalogRecord(id: remote, name: "\n", origin: .ssh, status: .unavailable,
            platform: .init(os: "../../private", arch: nil), capabilities: ["terminal", "bad/name", "terminal"]))
        #expect(record.name == remote.rawValue)
        #expect(record.platform == nil)
        #expect(record.capabilities == ["terminal"])
        let composed = try #require(MachineCatalogRecord(id: remote, name: String(repeating: "👩‍💻", count: 64), origin: .ssh, status: .running))
        #expect(composed.name.unicodeScalars.count <= 64)
    }

    @Test func identityMetadataIsOwnerObservedAndLegacyAbsenceStaysUnknown() throws {
        let prefix = #"{"app":"cmux-tui","protocol":12,"generation":"boot","machine_id":"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa""#
        let decoder = JSONDecoder()
        let known = try decoder.decode(DaemonIdentity.self, from: Data((prefix + #", "machine_platform":{"os":"linux","arch":"aarch64"},"machine_capabilities":["terminal"]}"#).utf8))
        #expect(known.machinePlatform?.os == "linux")
        #expect(known.machineCapabilities == ["terminal"])
        let legacy = try decoder.decode(DaemonIdentity.self, from: Data((prefix + "}").utf8))
        #expect(legacy.machinePlatform == nil && legacy.machineCapabilities.isEmpty)
        for field in [#", "machine_platform":{"os":1}}"#, #", "machine_capabilities":[1]}"#] {
            #expect(throws: (any Error).self) { try decoder.decode(DaemonIdentity.self, from: Data((prefix + field).utf8)) }
        }
    }
}
