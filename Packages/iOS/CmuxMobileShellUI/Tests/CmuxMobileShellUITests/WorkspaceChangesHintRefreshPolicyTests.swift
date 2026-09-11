import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@Test func hintSurvivesTransientReconnectWithoutRearming() {
    let hint = MobileWorkspaceChangesHint(
        workspaceID: "workspace-a",
        workspaceChangesCapable: true,
        chip: MobileWorkspaceChangesChip(filesChanged: 2, additions: 3, deletions: 1),
        isDismissed: false
    )
    var current = WorkspaceChangesHintRefreshPolicy.next(
        current: nil,
        isAvailable: true,
        candidate: hint
    )
    #expect(current == hint)

    current = WorkspaceChangesHintRefreshPolicy.next(
        current: current,
        isAvailable: false,
        candidate: nil
    )
    #expect(current == hint)

    current = WorkspaceChangesHintRefreshPolicy.next(
        current: current,
        isAvailable: true,
        candidate: hint
    )
    #expect(current == hint)
}

@Test func unavailableDetailDoesNotArmAHint() {
    let hint = MobileWorkspaceChangesHint(
        workspaceID: "workspace-a",
        workspaceChangesCapable: true,
        chip: MobileWorkspaceChangesChip(filesChanged: 2, additions: 3, deletions: 1),
        isDismissed: false
    )

    #expect(
        WorkspaceChangesHintRefreshPolicy.next(
            current: nil,
            isAvailable: false,
            candidate: hint
    ) == nil
    )
}

@Test func availableDetailClearsHintWhenChangesDisappear() {
    let hint = MobileWorkspaceChangesHint(
        workspaceID: "workspace-a",
        workspaceChangesCapable: true,
        chip: MobileWorkspaceChangesChip(filesChanged: 2, additions: 3, deletions: 1),
        isDismissed: false
    )

    #expect(
        WorkspaceChangesHintRefreshPolicy.next(
            current: hint,
            isAvailable: true,
            candidate: nil
        ) == nil
    )
}
