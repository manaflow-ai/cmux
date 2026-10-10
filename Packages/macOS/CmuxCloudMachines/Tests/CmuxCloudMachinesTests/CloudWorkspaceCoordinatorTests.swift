import Foundation
import Testing
@testable import CmuxCloudMachines

@MainActor
struct CloudWorkspaceCoordinatorTests {
    @Test("Issue 13184: A → local, B → local, then pin/reorder fallback ignores the old default")
    func concreteVerificationFlow() async throws {
        let suite = "cloud-target-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("a", forKey: "cloud.defaultMachineID")
        let pins = CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" })
        #expect(defaults.object(forKey: "cloud.defaultMachineID") == nil)
        pins.reconcile(machineIDs: ["b", "a"])
        // A stale writer restoring the retired preference cannot affect routing.
        defaults.set("a", forKey: "cloud.defaultMachineID")
        var requests: [CloudWorkspaceCreationRequest] = []
        let coordinator = CloudWorkspaceCoordinator(
            machinePinStore: pins, allowsOperation: { true },
            loadMachines: { ["a", "b"] },
            createWorkspace: { request in requests.append(request); return UUID() }
        )
        let state = coordinator.makeSelectionState()
        let windowID = UUID()
        let a = UUID(), b = UUID(), local = UUID()
        state.select(workspaceID: a, machineID: "a")
        state.select(workspaceID: local, machineID: nil)
        _ = try await coordinator.createOnResolvedMachine(selection: state.lastCloudSelection, windowID: windowID, scopeID: "scope")
        state.select(workspaceID: b, machineID: "b")
        state.select(workspaceID: local, machineID: nil)
        _ = try await coordinator.createOnResolvedMachine(selection: state.lastCloudSelection, windowID: windowID, scopeID: "scope")
        _ = try await coordinator.createOnResolvedMachine(selection: nil, windowID: windowID, scopeID: "scope")
        pins.setPinned(true, machineID: "a")
        _ = try await coordinator.createOnResolvedMachine(selection: nil, windowID: windowID, scopeID: "scope")
        pins.setPinned(true, machineID: "b")
        #expect(pins.move(.top, machineID: "b", machineIDs: ["a", "b"]))
        _ = try await coordinator.createOnResolvedMachine(selection: nil, windowID: windowID, scopeID: "scope")
        #expect(requests.map(\.machineID) == ["a", "b", "b", "a", "b"])
        #expect(requests.allSatisfy { $0.windowID == windowID && $0.scopeID == "scope" })
    }

    @Test("A deleted or cross-team machine falls back to the displayed order", arguments: [false, true])
    func invalidSelection(crossTeam: Bool) async throws {
        let suite = "cloud-target-stale-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = CloudMachinePinStore(defaults: defaults, scopeProvider: { "current" })
        pins.reconcile(machineIDs: ["b", "a"])
        var target: String?
        let coordinator = CloudWorkspaceCoordinator(
            machinePinStore: pins, allowsOperation: { true }, loadMachines: { ["a", "b"] },
            createWorkspace: { target = $0.machineID; return UUID() }
        )
        let selection = CloudWorkspaceSelection(
            workspaceID: UUID(), scopeID: crossTeam ? "other" : "current", machineID: crossTeam ? "a" : "deleted"
        )
        _ = try await coordinator.createOnResolvedMachine(selection: selection, windowID: UUID(), scopeID: "current")
        #expect(target == "b")
    }

    @Test("Empty fleet is explicit and never invokes creation")
    func emptyFleet() async throws {
        let suite = "cloud-target-empty-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = CloudWorkspaceCoordinator(
            machinePinStore: CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" }),
            allowsOperation: { true }, loadMachines: { [] },
            createWorkspace: { _ in Issue.record("Empty fleet must not create"); return nil }
        )
        await #expect(throws: CloudWorkspaceCreationError.noMachines) {
            try await coordinator.createOnResolvedMachine(selection: nil, windowID: UUID(), scopeID: "scope")
        }
    }

    @Test("Availability and scope changes fence both the load and the create", arguments: ["signed-out", "scope-before", "scope-during", "access-during", "cancel"])
    func availability(change: String) async throws {
        let suite = "cloud-target-gates-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope = change == "scope-before" ? "other" : "scope"
        var available = change != "signed-out"
        var loads = 0
        let coordinator = CloudWorkspaceCoordinator(
            machinePinStore: CloudMachinePinStore(defaults: defaults, scopeProvider: { scope }),
            allowsOperation: { available },
            loadMachines: {
                loads += 1
                if change == "scope-during" { scope = "other" }
                if change == "access-during" { available = false }
                if change == "cancel" { throw CancellationError() }
                return ["a"]
            },
            createWorkspace: { _ in Issue.record("Retired operation must not create"); return nil }
        )
        if change == "cancel" {
            await #expect(throws: CancellationError.self) {
                try await coordinator.createOnResolvedMachine(selection: nil, windowID: UUID(), scopeID: "scope")
            }
        } else {
            #expect(try await coordinator.createOnResolvedMachine(selection: nil, windowID: UUID(), scopeID: "scope") == nil)
        }
        #expect(loads == (["signed-out", "scope-before"].contains(change) ? 0 : 1))
    }

    @Test("Later selection cannot redirect an intent already resolving or overwrite its memory")
    func selectionDuringLoad() async throws {
        let suite = "cloud-target-race-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = CloudWorkspaceSelectionState(scopeProvider: { "scope" })
        state.select(workspaceID: UUID(), machineID: "a")
        let selection = state.lastCloudSelection
        let revision = state.revision
        var target: String?
        let coordinator = CloudWorkspaceCoordinator(
            machinePinStore: CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" }),
            allowsOperation: { true },
            loadMachines: { state.select(workspaceID: UUID(), machineID: "b"); return ["b", "a"] },
            createWorkspace: { target = $0.machineID; return UUID() }
        )
        _ = try await coordinator.createOnResolvedMachine(selection: selection, windowID: UUID(), scopeID: "scope")
        #expect(target == "a")
        #expect(state.lastCloudSelection?.machineID == "b")
        #expect(state.revision != revision)
    }
}
