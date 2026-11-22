import SwiftUI

/// A small gray capsule button. `prominent` fills it with the text color.
struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var help: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.serverColors) private var colors
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 9).frame(height: 22)
            .foregroundStyle(prominent ? colors.onPrimary : colors.primary)
            .background(Capsule().fill(prominent ? colors.primary.opacity(hovering ? 0.85 : 1) : (hovering ? colors.hover : colors.fill)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// The Fix button of an alert: a lock glyph when the fix asks for an
/// administrator once, an arrow when it opens a settings pane.
struct FixButton: View {
    let model: ServerModel
    let check: HealthCheckID
    let fix: HealthFix

    var body: some View {
        PillButton(title: fix.title, symbol: fix.needsAdmin ? "lock.fill" : (fix.opensSettings ? "arrow.up.forward" : nil),
                   help: fix.needsAdmin ? ServerStrings.needsAdmin : nil) {
            model.fix(check)
        }
        .disabled(model.isFixing(check))
    }
}
