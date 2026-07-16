import SwiftUI
import CmuxSubrouterUI

/// The thin app-target shim mounting the packaged Agents panel with the
/// shared app-owned store (mirrors how `FeedPanelView` reaches its
/// coordinator).
struct SubrouterAgentsPanelHostView: View {
    var body: some View {
        AgentsPanelView(store: SubrouterAppRuntime.shared.store)
    }
}
