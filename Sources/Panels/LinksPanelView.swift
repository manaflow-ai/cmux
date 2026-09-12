import AppKit
import SwiftUI

struct LinksPanelView: View {
    let panel: LinksPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The workspace/window backdrop owns the resolved terminal
            // appearance. Keeping this surface transparent lets the same
            // backdrop show through in both a standalone pane and the right
            // sidebar, instead of introducing AppKit's ambient window color.
            Color.clear
                .ignoresSafeArea()
            if let workspace = panel.workspace {
                ArtifactsPaneContent(
                    workspace: workspace,
                    artifactsState: workspace.artifactsState,
                    titleFetcher: panel.titleFetcher,
                    isFocused: isFocused
                )
            } else {
                Text(String(
                    localized: "artifactsPane.workspaceUnavailable",
                    defaultValue: "This workspace is no longer available."
                ))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
    }
}
