import SwiftUI

struct WorkspaceTaskIconButton: View {
    let systemName: String
    let label: String
    var role: ButtonRole? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .cmuxSymbolRasterSize(12)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
