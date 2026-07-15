import CmuxSettingsUI
import SwiftUI

struct AppUtilityPanelView: View {
    @Bindable var panel: AppUtilityPanel

    var body: some View {
        Group {
            switch panel.kind {
            case .settings:
                if let runtime = AppDelegate.shared?.settingsRuntime {
                    SettingsWindowRoot(
                        runtime: runtime,
                        navigationScope: panel.settingsNavigationScope,
                        initialNavigationSection: panel.settingsNavigationTarget.flatMap {
                            SettingsSectionID(rawValue: $0.rawValue)
                        },
                        presentationStyle: .pane
                    )
                    .settingsRuntime(runtime)
                    .task(id: panel.settingsNavigationRevision) {
                        guard panel.settingsNavigationRevision > 0 else { return }
                        guard let target = panel.settingsNavigationTarget else { return }
                        SettingsNavigationRequest.post(
                            target,
                            scope: panel.settingsNavigationScope
                        )
                    }
                } else {
                    Text(String(
                        localized: "settings.window.runtimeUnavailable",
                        defaultValue: "Settings could not load. Please restart cmux and report this issue."
                    ))
                    .padding(40)
                }
            case .mobilePairing:
                MobilePairingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
        .background(
            RightSidebarToolFocusAnchor(onViewChange: panel.attachFocusAnchor)
                .frame(width: 0, height: 0)
        )
    }
}
