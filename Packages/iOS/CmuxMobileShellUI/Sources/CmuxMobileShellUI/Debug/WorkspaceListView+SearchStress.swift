#if canImport(UIKit) && DEBUG
import CmuxMobileShellModel
import SwiftUI

extension WorkspaceListView {
    /// Exercises live workspace snapshot replacement only after the preview's
    /// authoritative search binding becomes active.
    func workspaceSearchStressScenario(
        workspaces: Binding<[MobileWorkspacePreview]>
    ) -> some View {
        modifier(
            WorkspaceSearchStressScenario(
                searchText: searchText,
                workspaces: workspaces
            )
        )
    }
}

private struct WorkspaceSearchStressScenario: ViewModifier {
    let searchText: String
    @Binding var workspaces: [MobileWorkspacePreview]
    @State private var isComplete = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isComplete {
                    Text("MobileWorkspaceSearchStressComplete")
                        .font(.caption2)
                        .accessibilityIdentifier("MobileWorkspaceSearchStressComplete")
                }
            }
            .task(id: searchText) {
                guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    isComplete = false
                    return
                }

                isComplete = false
                for revision in 0..<400 {
                    guard !Task.isCancelled else { return }
                    workspaces[0].previewText = "Build output revision \(revision)"
                    await Task.yield()
                }
                isComplete = true
            }
    }
}
#endif
