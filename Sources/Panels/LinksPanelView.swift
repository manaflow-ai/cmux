import AppKit
import SwiftUI

struct LinksPanelView: View {
    let panel: LinksPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            if let workspace = panel.workspace {
                LinksPaneContent(
                    workspace: workspace,
                    linksState: workspace.linksState,
                    titleFetcher: panel.titleFetcher,
                    isFocused: isFocused
                )
            } else {
                Text(String(
                    localized: "linksPane.workspaceUnavailable",
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
