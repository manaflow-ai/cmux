import Foundation
@testable import CmuxWorkspaces

/// Records whether the model's id index matches incoming tabs in its hook.
@MainActor
final class IndexProbeHost: WorkspacesHosting {
    typealias Tab = ObservedStubTab
    weak var model: WorkspacesModel<ObservedStubTab>?
    private(set) var indexMatchedIncomingTabs: [Bool] = []

    func workspaceTabsWillChange(to newValue: [ObservedStubTab]) {
        guard let model else { return }
        let incoming = Set(newValue.map(\.id))
        indexMatchedIncomingTabs.append(
            Set(model.tabsById.keys) == incoming
                && newValue.allSatisfy { model.tabsById[$0.id] === $0 }
        )
    }

    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {}
    func selectedWorkspaceIdWillChange(to newValue: UUID?) {}
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {}
}
