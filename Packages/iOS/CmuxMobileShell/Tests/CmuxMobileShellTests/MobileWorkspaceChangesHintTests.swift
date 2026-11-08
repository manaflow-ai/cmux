import CmuxMobileShell
import Foundation
import Testing

@Suite
struct MobileWorkspaceChangesHintTests {
    @Test
    func eligibilityRequiresCapabilityChangesAndUnseenWorkspace() {
        let chip = MobileWorkspaceChangesChip(filesChanged: 2, additions: 8, deletions: 3)

        #expect(MobileWorkspaceChangesHint(
            workspaceID: "workspace-a",
            workspaceChangesCapable: true,
            chip: chip,
            isDismissed: false
        )?.workspaceID == "workspace-a")
        #expect(MobileWorkspaceChangesHint(
            workspaceID: "workspace-a",
            workspaceChangesCapable: false,
            chip: chip,
            isDismissed: false
        ) == nil)
        #expect(MobileWorkspaceChangesHint(
            workspaceID: "workspace-a",
            workspaceChangesCapable: true,
            chip: nil,
            isDismissed: false
        ) == nil)
        #expect(MobileWorkspaceChangesHint(
            workspaceID: "workspace-a",
            workspaceChangesCapable: true,
            chip: chip,
            isDismissed: true
        ) == nil)
    }

    @Test
    func dismissalPersistsPerWorkspace() throws {
        let suiteName = "workspace-changes-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileWorkspaceChangesHintDismissalStore(defaults: defaults)

        store.dismiss(workspaceID: "workspace-a")

        #expect(store.isDismissed(workspaceID: "workspace-a"))
        #expect(!store.isDismissed(workspaceID: "workspace-b"))
    }
}
