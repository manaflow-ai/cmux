#if os(iOS)
import CmuxConversation
import CmuxMobileAgent
import CmuxMobileShell
import SwiftUI

/// Opens the agent conversations of the connected Mac. Shown only while the
/// Mac relays its acpmux (capability `acpmux_lane.v1`).
struct AgentsToolbarButton: View {
    let store: CMUXMobileShellStore?
    @State private var presented = false

    var body: some View {
        if let backend = store?.agentBackend {
            Button { presented = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                .accessibilityLabel(String(localized: "mobile.agents.title", defaultValue: "Agents", bundle: .module))
                .accessibilityIdentifier("MobileWorkspaceAgentsButton")
                .sheet(isPresented: $presented) {
                    let support = URL.applicationSupportDirectory.appending(path: "agent", directoryHint: .isDirectory)
                    AgentConversationsView(
                        backend: backend,
                        outbox: FileOutboxStore(directory: support.appending(path: "outbox", directoryHint: .isDirectory)),
                        filesDirectory: support.appending(path: "files", directoryHint: .isDirectory)
                    )
                }
        }
    }
}
#endif
