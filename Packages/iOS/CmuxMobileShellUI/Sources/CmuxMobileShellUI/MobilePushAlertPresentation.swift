#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobilePushAlertPresentationModifier: ViewModifier {
    let coordinator: MobilePushCoordinator
    @State private var presentedAlert: MobilePushCoordinator.TabUnavailableAlert?

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.tabUnavailableAlert, initial: true) { _, alert in
                presentedAlert = alert
            }
            .alert(item: $presentedAlert) { alert in
                switch alert.kind {
                case .tabUnavailable:
                    Alert(
                        title: Text(L10n.string(
                            "mobile.push.tabUnavailable.title",
                            defaultValue: "Tab unavailable"
                        )),
                        message: Text(L10n.string(
                            "mobile.push.tabUnavailable.message",
                            defaultValue: "This tab is no longer available on your Mac."
                        )),
                        dismissButton: .default(Text(L10n.string(
                            "mobile.common.ok",
                            defaultValue: "OK"
                        ))) {
                            coordinator.dismissTabUnavailableAlert()
                        }
                    )
                }
            }
    }
}

extension View {
    func mobilePushAlertPresentation(
        coordinator: MobilePushCoordinator
    ) -> some View {
        modifier(MobilePushAlertPresentationModifier(coordinator: coordinator))
    }
}
#endif
