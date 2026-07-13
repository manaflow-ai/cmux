#if canImport(UIKit) && DEBUG
import CmuxMobileShellModel
import SwiftUI
import UIKit

extension View {
    /// Exercises live workspace snapshot replacement only after the preview's
    /// authoritative search binding becomes active.
    func workspaceSearchStressScenario(
        workspaces: Binding<[MobileWorkspacePreview]>
    ) -> some View {
        modifier(
            WorkspaceSearchStressScenario(
                workspaces: workspaces
            )
        )
    }
}

private struct WorkspaceSearchStressScenario: ViewModifier {
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
            .task {
                for await notification in NotificationCenter.default.notifications(
                    named: UITextField.textDidChangeNotification
                ) {
                    guard let field = notification.object as? UISearchTextField,
                          let text = field.text,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    break
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
