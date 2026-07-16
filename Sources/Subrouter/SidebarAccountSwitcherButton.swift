import SwiftUI
import CmuxAppKitSupportUI
import CmuxSubrouter
import CmuxSubrouterUI

/// The compact left-sidebar footer affordance for AI-agent account
/// switching: a person icon with a status dot reflecting the active
/// accounts' health, opening the quick-switch popover.
///
/// Rendered only while the subrouter integration and the footer switcher
/// setting are both on (the caller gates on
/// `SubrouterIntegrationSettings.showsAccountSwitcher`). Registers footer
/// visibility with ``SubrouterAppRuntime`` so the slow background poll runs
/// only while the button is actually on screen and the app is active.
struct SidebarAccountSwitcherButton: View {
    @State private var isPopoverPresented = false

    var body: some View {
        let store = SubrouterAppRuntime.shared.store
        let snapshot = store.snapshot
        Button {
            isPopoverPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(magnified: "person.2", pointSize: 12, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 22, height: 22, alignment: .center)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusDotColor(snapshot: snapshot))
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .offset(x: -2, y: -3)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: 22, height: 22, alignment: .center)
        .safeHelp(String(localized: "subrouter.footer.tooltip", defaultValue: "Agent Accounts"))
        .accessibilityLabel(String(localized: "subrouter.footer.tooltip", defaultValue: "Agent Accounts"))
        .accessibilityIdentifier("SidebarAccountSwitcherButton")
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SubrouterAccountSwitcherPopoverView(store: store)
        })
        .onAppear { SubrouterAppRuntime.shared.footerSwitcherDidAppear() }
        .onDisappear { SubrouterAppRuntime.shared.footerSwitcherDidDisappear() }
    }

    private func statusDotColor(snapshot: SubrouterSnapshot) -> Color {
        switch snapshot.daemonState {
        case .unknown:
            return Color(nsColor: .tertiaryLabelColor)
        case .unreachable:
            return .red
        case .healthy:
            return snapshot.attentionCount > 0 ? .orange : .green
        }
    }
}
