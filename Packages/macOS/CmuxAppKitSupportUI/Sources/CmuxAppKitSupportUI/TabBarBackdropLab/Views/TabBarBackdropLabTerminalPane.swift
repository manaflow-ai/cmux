#if canImport(AppKit)

internal import SwiftUI
internal import AppKit

/// The mock terminal pane content rendered inside each `Bonsplit` tab of a
/// ``TabBarBackdropLabSample``: a transparent fill over the variant's terminal
/// color plus monospaced sample text whose titles intentionally overflow under
/// the split buttons.
struct TabBarBackdropLabTerminalPane: View {
    let title: String
    let color: NSColor
    let opacity: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: color.withAlphaComponent(opacity))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(String(localized: "debug.tabBarBackdropLab.terminal.prompt", defaultValue: "lawrence in ~/cmux")) \(title)")
                    .foregroundStyle(Color.green)
                Text(String(localized: "debug.tabBarBackdropLab.terminal.overflow", defaultValue: "tab titles intentionally overflow under the split buttons"))
                    .foregroundStyle(Color.white.opacity(0.78))
                Text(String(localized: "debug.tabBarBackdropLab.terminal.compare", defaultValue: "drag / resize / compare the transparent edges"))
                    .foregroundStyle(Color.white.opacity(0.52))
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(10)
        }
    }
}

#endif
