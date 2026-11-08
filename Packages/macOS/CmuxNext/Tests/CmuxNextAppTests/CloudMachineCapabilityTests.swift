@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

@Suite
struct CloudMachineCapabilityTests {
    @Test func cmuxNextBackendRecordsKeepCloudActions() throws {
        let record = JSONValue.object([
            "id": .string("m-1"), "status": .string("running"), "capabilities": .array([.string("agent_session")]),
        ])
        let machine = try #require(CloudMachine(next: record))

        #expect(machine.allows(.ports))
        #expect(machine.allows(.fork))
    }

    @Test func cmuxNextRecordThatServesDesktopOpensTheRdViewer() throws {
        let record = JSONValue.object([
            "id": .string("m-desk"), "status": .string("running"), "desktop": .bool(true),
            "creator": .string("user_u0000000000000000001"), "capabilities": .array([.string("agent_session")]),
        ])
        let machine = try #require(CloudMachine(next: record))

        #expect(machine.servesDesktop)
        #expect(machine.capabilities.desktop)
        #expect(machine.allows(.desktop))
        #expect(machine.defaultDesktopViewer(for: "user_u0000000000000000001") == "rd")
        // The rd stream is the creator's alone: a teammate, or no signed-in user, keeps the noVNC page.
        #expect(machine.defaultDesktopViewer(for: "user_u0000000000000000002") == "web")
        #expect(machine.defaultDesktopViewer(for: nil) == "web")
        // Serving the desktop declares nothing else: the other actions keep the undeclared default.
        #expect(machine.declaredCapabilities == nil)
        #expect(machine.allows(.ports))
        #expect(machine.allows(.fork))
    }

    @Test func cmuxNextRecordWithoutDesktopKeepsTheWebViewer() throws {
        for record in [
            JSONValue.object(["id": .string("m-old"), "status": .string("running")]),
            JSONValue.object(["id": .string("m-off"), "status": .string("running"), "desktop": .bool(false)]),
        ] {
            let machine = try #require(CloudMachine(next: record))
            #expect(!machine.servesDesktop)
            #expect(!machine.capabilities.desktop)
            #expect(machine.defaultDesktopViewer(for: "user_u0000000000000000001") == "web")
        }
    }

    @Test func declaredCapabilitiesGainDesktopWhenTheRecordServesIt() throws {
        let record = JSONValue.object([
            "id": .string("m-ops"), "desktop": .bool(true), "provider_operations": .array([.string("exec")]),
        ])
        let machine = try #require(CloudMachine(next: record))

        #expect(machine.allows(.desktop))
        #expect(machine.capabilities.desktop)
        #expect(machine.allows(.exec))
        #expect(!machine.allows(.snapshot))
    }
}
