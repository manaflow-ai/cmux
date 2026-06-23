import SwiftUI

extension CMUXMobileRootView {
    @ViewBuilder var terminalLayoutPreview: some View {
        #if os(iOS) && DEBUG
        TerminalLayoutPreviewView()
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder var workspaceListLayoutPreview: some View {
        #if os(iOS) && DEBUG
        WorkspaceListLayoutPreviewView()
        #else
        EmptyView()
        #endif
    }
}
