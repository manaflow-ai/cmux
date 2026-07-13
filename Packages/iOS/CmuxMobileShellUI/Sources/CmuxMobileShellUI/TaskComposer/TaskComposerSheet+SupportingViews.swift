#if os(iOS)
import CmuxMobilePairedMac
import SwiftUI

extension TaskComposerSheet {
    @ViewBuilder
    func machineIcon(_ mac: MobilePairedMac) -> some View {
        switch MacAvatarIcon.resolve(custom: mac.customIcon, defaultSymbol: "desktopcomputer") {
        case .symbol(let name):
            Image(systemName: name)
                .accessibilityHidden(true)
        case .emoji(let emoji):
            Text(emoji)
                .accessibilityHidden(true)
        }
    }

    func validationText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
#endif
