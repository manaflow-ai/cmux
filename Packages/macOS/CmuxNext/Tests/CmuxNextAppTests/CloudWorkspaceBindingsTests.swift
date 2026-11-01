import CmuxNextCloud
import Foundation
import Testing

@Suite @MainActor struct CloudWorkspaceBindingsTests {
    private let logical = "vm_aaaaaaaaaaaaaaaaaaaa"
    private let replacement = "vm_bbbbbbbbbbbbbbbbbbbb"
    private let scope = CloudWorkspaceBindings.Scope(user: "user_one", team: nil, origin: "https://platform.test")

    private func binding() throws -> CloudWorkspaceBindings.Binding {
        let store = CloudWorkspaceBindings()
        try store.remember(workspace: "ws_one", machine: logical, scope: scope)
        return try #require(store.bindings(in: scope).first)
    }

    private func record(_ state: String = "running", machine: String? = nil, provider: String = "freestyle") -> Data {
        Data("""
        {"workspace":"ws_one","machine":{"id":"\(machine ?? logical)","provider":"\(provider)","state":"\(state)","creator":"user_one","createdAt":1000}}
        """.utf8)
    }

    private func connection(provider: String = "freestyle", machine: String? = nil, generation: Int = 3) -> Data {
        Data("""
        {"machineId":"\(logical)","generation":\(generation),"provider":"\(provider)","connectionMachine":"\(machine ?? replacement)"}
        """.utf8)
    }

    @Test func restartKeepsBindingAndAccountIsolation() throws {
        let name = "CloudWorkspaceBindingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = CloudWorkspaceBindings()
        first.defaults = { defaults }
        try first.remember(workspace: "ws_one", machine: logical, scope: scope, target: replacement)
        let restored = CloudWorkspaceBindings()
        restored.defaults = { defaults }
        let saved = try #require(restored.bindings(in: scope).first)
        #expect(saved.workspace == "ws_one")
        #expect(saved.machine == logical)
        #expect(saved.targets == Set([logical, replacement]))
        #expect(try restored.bindings(in: .init(user: "user_two", team: nil, origin: scope.origin)).isEmpty)
        #expect(try restored.bindings(in: .init(user: scope.user, team: "team_other", origin: scope.origin)).isEmpty)
        #expect(try restored.bindings(in: .init(user: scope.user, team: nil, origin: "https://other.test")).isEmpty)
    }

    @Test func replacementListKeepsLogicalIdentityWhenSourceIsAbsent() async throws {
        let record = record(), connection = connection()
        let projection = try await CloudWorkspaceProjection.read(binding: binding(), machine: { _ in record }, connection: { _ in connection })
        let unrelated = CloudMachine(id: "vm_unrelated", displayName: "Other")
        let rows = CloudWorkspaceProjection.applying([projection], to: [CloudMachine(id: replacement, displayName: "Project"), unrelated])
        #expect(rows.map(\.id) == [unrelated.id, logical])
        #expect(rows.last?.displayName == "Project")
        #expect(rows.last?.status == .running)
        #expect(projection.connection?.generation == 3)
        // The workspace still appears before the carrier row has reached CloudDO's list.
        #expect(CloudWorkspaceProjection.applying([projection], to: []).map(\.id) == [logical])
    }

    @Test func sourceCleanupCannotOverwriteAuthoritativeState() async throws {
        let record = record("paused"), connection = connection()
        let projection = try await CloudWorkspaceProjection.read(binding: binding(), machine: { _ in record }, connection: { _ in connection })
        let rows = CloudWorkspaceProjection.applying([projection], to: [
            CloudMachine(id: logical, status: .destroyed), CloudMachine(id: replacement, status: .running),
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.id == logical)
        #expect(rows.first?.status == .paused)
    }

    @Test func uncertainOwnerReadAndMissingCarrierDoNotBecomeDeletion() async throws {
        let binding = try binding(), record = record()
        await #expect(throws: CloudTurnRewindClient.Failure.self) {
            try await CloudWorkspaceProjection.read(binding: binding, machine: { _ in throw CloudTurnRewindClient.Failure.http(503) },
                                                    connection: { _ in throw CloudTurnRewindClient.Failure.http(404) })
        }
        await #expect(throws: CloudTurnRewindClient.Failure.self) {
            try await CloudWorkspaceProjection.read(binding: binding, machine: { _ in record },
                                                    connection: { _ in throw CloudTurnRewindClient.Failure.http(404) })
        }
    }

    @Test func confirmedDeletionRemovesLogicalAndRetiredCarrierRows() async throws {
        let store = CloudWorkspaceBindings()
        try store.remember(workspace: "ws_one", machine: logical, scope: scope, target: replacement)
        let binding = try #require(store.bindings(in: scope).first)
        let projection = try await CloudWorkspaceProjection.read(binding: binding,
            machine: { _ in throw CloudTurnRewindClient.Failure.http(404) },
            connection: { _ in Issue.record("A deleted binding must not resolve a carrier"); return Data() })
        #expect(CloudWorkspaceProjection.applying([projection], to: [CloudMachine(id: logical), CloudMachine(id: replacement)]).isEmpty)
    }

    @Test(arguments: ["freestyle-vm-api", "freestyle-cloud"])
    func boundCarrierKeepsTheLogicalWorkspaceIdentity(provider: String) async throws {
        let record = record(provider: provider), target = connection(provider: provider)
        let projection = try await CloudWorkspaceProjection.read(binding: binding(), machine: { _ in record }, connection: { _ in target })
        #expect(projection.connection?.connectionMachine == replacement)
        let rows = CloudWorkspaceProjection.applying([projection], to: [CloudMachine(id: replacement)])
        #expect(rows.map(\.id) == [logical])
        #expect(rows.first?.provider == provider)
    }

    @Test func rawVMAPIOrWrongLogicalMachineNeverBecomesAnAppLink() async throws {
        let binding = try binding(), record = record()
        for connection in [connection(provider: "unknown"), connection(provider: "freestyle-vm-api", machine: "vm_abcdefghijklmnopqrstuvwxyz"), connection(machine: "vm_abcdefghijklmnopqrstuvwxyz"), connection(machine: "vm_abcdefghijklmnopqrst\\n"), connection(generation: -1)] {
            await #expect(throws: CloudTurnRewindClient.Failure.self) {
                try await CloudWorkspaceProjection.read(binding: binding, machine: { _ in record }, connection: { _ in connection })
            }
        }
        let wrongRecord = self.record(machine: replacement), target = connection()
        await #expect(throws: CloudTurnRewindClient.Failure.self) {
            try await CloudWorkspaceProjection.read(binding: binding, machine: { _ in wrongRecord }, connection: { _ in target })
        }
    }

    @Test func corruptRegistryFailsClosedInsteadOfForgettingBindings() throws {
        let name = "CloudWorkspaceBindingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: "bindings")
        let store = CloudWorkspaceBindings(key: "bindings")
        store.defaults = { defaults }
        #expect(throws: (any Error).self) { try store.bindings(in: scope) }
    }
}
