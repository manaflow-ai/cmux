#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Renders a task template's icon: an SF Symbol name or a single emoji.
struct TaskTemplateIcon: View {
    let value: String

    var body: some View {
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
#endif
