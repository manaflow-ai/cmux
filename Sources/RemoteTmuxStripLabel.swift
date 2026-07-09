import Bonsplit
import SwiftUI

/// Shared active-pane dot plus header text for imposed and transient strips.
struct RemoteTmuxStripLabel: View {
    let label: String
    let isActive: Bool
    let appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 5) {
            if isActive {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        Color(nsColor: appearance.foregroundColor)
                            .opacity(isActive ? 0.95 : 0.65)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 5)
        .background(Color(nsColor: appearance.backgroundColor))
    }
}
