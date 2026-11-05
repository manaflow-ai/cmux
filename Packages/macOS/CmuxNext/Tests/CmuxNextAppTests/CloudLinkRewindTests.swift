import CmuxNextCloud
import Foundation
import Testing

@Suite struct CloudLinkRewindTests {
    actor Resolver: CloudLinkResolver {
        var opened: [String] = []
        var closed: [String] = []
        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            opened.append(key.machine)
            return CloudLinkSocket(key: key, path: "/tmp/\(key.machine).sock", generation: 1, callerOwnsVM: true)
        }
        func close(_ key: CloudLinkKey) async { closed.append(key.machine) }
    }

    @Test func replacementChangesTransportWithoutChangingLogicalIdentity() async throws {
        let resolver = Resolver(), logical = CloudLinkKey(machine: "vm_logical")
        let link = CloudLinkSession(key: logical, resolver: resolver)
        let original = try await link.connect(origin: .user)
        #expect(await link.ownerLink != nil)
        #expect(await link.retarget(machine: "vm_replacement", generation: 1))
        #expect(link.key == logical)
        #expect(await link.ownerLink == nil)
        #expect(await link.isConnected(machine: "vm_replacement", generation: 1) == false)
        await #expect(throws: CloudLinkError.self) { try await link.endpoint(original) }
        let replacement = try await link.connect(origin: .user)
        #expect(try await link.endpoint(replacement) == "/tmp/vm_replacement.sock")
        #expect(await link.isConnected(machine: "vm_replacement", generation: 1))
        #expect(await link.isConnected(machine: "vm_logical", generation: 0) == false)
        #expect(await resolver.opened == ["vm_logical", "vm_replacement"])
        #expect(await resolver.closed == ["vm_logical"])
        #expect(await link.retarget(machine: "vm_replacement", generation: 1))
        #expect(await resolver.closed == ["vm_logical"])
        #expect(await link.retarget(machine: "vm_old", generation: 0) == false)
        #expect(await link.retarget(machine: "vm_other", generation: 1) == false)
        await link.close()
        #expect(await resolver.closed == ["vm_logical", "vm_replacement"])
    }
    @Test func provisioningSupersedesTheSameGenerationConnection() async throws {
        let resolver = Resolver(), logical = CloudLinkKey(machine: "vm_logical")
        let link = CloudLinkSession(key: logical, resolver: resolver)
        #expect(await link.retarget(machine: logical.machine, generation: 0))
        let original = try await link.connect(origin: .user)
        #expect(await link.isConnected(machine: logical.machine, generation: 0))
        #expect(await link.retarget(machine: logical.machine, generation: 0, forceReconnect: true))
        #expect(await link.ownerLink == nil)
        await #expect(throws: CloudLinkError.self) { try await link.endpoint(original) }
        let fresh = try await link.connect(origin: .user)
        #expect(try await link.endpoint(fresh) == "/tmp/vm_logical.sock")
        #expect(await link.isConnected(machine: logical.machine, generation: 0))
        #expect(await resolver.opened == ["vm_logical", "vm_logical"])
        #expect(await link.retarget(machine: "vm_other", generation: 0, forceReconnect: true) == false)
        #expect(await link.retarget(machine: logical.machine, generation: -1, forceReconnect: true) == false)
        await link.close()
    }
}
