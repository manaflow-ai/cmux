#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Renders a task template's icon: a bundled agent brand image (`agent:`
/// values), an SF Symbol name, or a single emoji.
struct TaskTemplateIcon: View {
    let value: String

    var body: some View {
        if let assetName = MobileTaskTemplate.agentIconAssetName(for: value) {
            Image(assetName, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            switch MacAvatarIcon.resolve(custom: value, defaultSymbol: "terminal") {
            case .symbol(let name):
                Image(systemName: name)
                    .accessibilityHidden(true)
            case .emoji(let emoji):
                Text(emoji)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif
