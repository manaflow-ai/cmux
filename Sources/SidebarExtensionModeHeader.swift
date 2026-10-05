import AppKit
import SwiftUI

/// Shared, permanent navigation between the native and Cortex sidebar modes.
/// Inputs are values; choosing a disabled Cortex offers the recovery flow.
struct SidebarExtensionModeHeader: View {
    static let height: CGFloat = 36
    let isCortexSelected: Bool
    let canActivateCortex: Bool
    let onSelectClassic: () -> Void
    let onSelectCortex: () -> Void
    let onManage: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker(String(localized: "sidebar.mode.label", defaultValue: "Sidebar view"), selection: Binding(
                get: { isCortexSelected },
                set: { if $0 { onSelectCortex() } else { onSelectClassic() } }
            )) {
                Text(String(localized: "sidebar.mode.classic", defaultValue: "Classic")).tag(false)
                Text(String(localized: "sidebar.mode.cortex", defaultValue: "Cortex")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(canActivateCortex
                ? String(localized: "sidebar.mode.help", defaultValue: "Choose the sidebar view")
                : String(localized: "sidebar.mode.recover.help", defaultValue: "Cortex is unavailable. Select Cortex to enable or manage the extension."))
            Button(action: onManage) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help(String(localized: "sidebar.mode.manage", defaultValue: "Manage Cortex"))
            .accessibilityLabel(String(localized: "sidebar.mode.manage", defaultValue: "Manage Cortex"))
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .accessibilityIdentifier("sidebar.modeSelector")
    }
}
