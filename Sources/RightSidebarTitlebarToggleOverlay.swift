import SwiftUI

/// Hosts the right-sidebar toggle in custom title-bar modes.
struct RightSidebarTitlebarToggleOverlay: View {
    let isPresented: Bool
    let config: TitlebarControlsStyleConfig
    let isVisible: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if isPresented {
            RightSidebarTitlebarToggleButton(
                config: config,
                isVisible: isVisible,
                foregroundColor: .primary,
                action: action
            )
            .environment(\.colorScheme, colorScheme)
            .frame(
                height: max(1, WindowChromeMetrics.appTitlebarHeight - 2),
                alignment: .center
            )
            .padding(.top, 2)
            .padding(.trailing, 8)
        }
    }
}
