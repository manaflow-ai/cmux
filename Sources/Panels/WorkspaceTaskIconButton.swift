import SwiftUI

struct WorkspaceTaskIconButton: View {
    let systemName: String
    let label: String
    var role: ButtonRole? = nil
    var isDisabled = false
    var foregroundStyle: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            CmuxSystemSymbolImage(magnified: systemName, pointSize: 12)
                .foregroundStyle(foregroundStyle)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
