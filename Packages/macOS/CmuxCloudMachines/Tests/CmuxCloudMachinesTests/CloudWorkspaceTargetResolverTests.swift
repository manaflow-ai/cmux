import Foundation
import Testing
@testable import CmuxCloudMachines

struct CloudWorkspaceTargetResolverTests {
    private let resolver = CloudWorkspaceTargetResolver()

    @Test func prefersTheLastCloudSelectionWhenItsMachineIsVisible() {
        let selection = CloudWorkspaceSelection(workspaceID: UUID(), scopeID: "scope", machineID: "a")

        #expect(resolver.resolve(
            lastSelection: selection,
            currentScopeID: "scope",
            sidebarMachineIDs: ["b", "a"]
        ) == "a")
    }

    @Test func fallsBackToTheFirstPresentedMachineIncludingPinnedReorder() {
        #expect(resolver.resolve(
            lastSelection: nil,
            currentScopeID: "scope",
            sidebarMachineIDs: ["b", "a"]
        ) == "b")
    }

    @Test(arguments: [
        CloudWorkspaceSelection(workspaceID: UUID(), scopeID: "scope", machineID: "deleted"),
        CloudWorkspaceSelection(workspaceID: UUID(), scopeID: "other-scope", machineID: "a")
    ]) func ignoresStaleDeletedAndCrossTeamSelections(selection: CloudWorkspaceSelection) {
        #expect(resolver.resolve(
            lastSelection: selection,
            currentScopeID: "scope",
            sidebarMachineIDs: ["b", "a"]
        ) == "b")
    }

    @Test func emptySidebarHasNoCloudTarget() {
        let selection = CloudWorkspaceSelection(workspaceID: UUID(), scopeID: "scope", machineID: "a")

        #expect(resolver.resolve(
            lastSelection: selection,
            currentScopeID: "scope",
            sidebarMachineIDs: []
        ) == nil)
    }

    @Test func signedOutScopeDoesNotUseSidebarRows() {
        #expect(resolver.resolve(lastSelection: nil, currentScopeID: nil, sidebarMachineIDs: ["b", "a"]) == nil)
    }
}
