import CmuxMobileSupport
import SwiftUI

extension CMUXMobileRootView {
    var shouldShowAgentChatDemoPreview: Bool {
        #if os(iOS) && DEBUG
        UITestConfig.agentChatPreviewEnabled || UITestConfig.agentChatInlinePreviewEnabled
        #else
        false
        #endif
    }

    @ViewBuilder var agentChatDemoPreview: some View {
        #if os(iOS) && DEBUG
        if UITestConfig.agentChatInlinePreviewEnabled {
            AgentChatDemoScreen(style: .inlineWorkspace)
        } else if UITestConfig.agentChatPreviewEnabled {
            AgentChatDemoScreen()
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }
}
