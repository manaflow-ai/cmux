import CMUXMobileCore
import CmuxMobileShellModel
import SwiftUI

/// Immutable terminal chip rendered below the toolbar in the inline-tabs variant.
struct WorkspaceInlineTerminalTab: View {
    let row: TerminalPickerMenuRow
    let isSelected: Bool
    let terminalTheme: TerminalTheme
    let select: (MobileTerminalPreview.ID) -> Void

    var body: some View {
        Button {
            select(row.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "terminal")
                    .font(.caption.weight(.semibold))
                Text(row.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                terminalTheme.terminalChromeForegroundColor.opacity(isSelected ? 0.17 : 0.07),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        terminalTheme.terminalChromeForegroundColor.opacity(isSelected ? 0.35 : 0.10),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("MobileInlineTerminalTab-\(row.id.rawValue)")
    }
}
