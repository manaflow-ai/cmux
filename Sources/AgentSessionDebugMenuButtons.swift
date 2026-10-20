import SwiftUI

#if DEBUG
struct AgentSessionDebugMenuButtons: View {
    let openReact: () -> Void
    let openSolid: () -> Void

    var body: some View {
        Button(
            String(
                localized: "debug.menu.openAgentGuiReact",
                defaultValue: "Open Agent GUI (React)"
            )
        ) {
            openReact()
        }

        Button(
            String(
                localized: "debug.menu.openAgentGuiSolid",
                defaultValue: "Open Agent GUI (Solid)"
            )
        ) {
            openSolid()
        }
    }
}
#endif
