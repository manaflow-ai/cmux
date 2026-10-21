import CmuxHomeCore
import CmuxNextDesign
import SwiftUI

/// One person Add People offers: a check, the name and where they come from (team or contact).
/// A value snapshot plus a closure (no model below the list).
struct HomeGroupContactRow: View {
    let contact: HomeContact
    let isChosen: Bool
    let colors: HomeGroupInfoColors
    let onToggle: @MainActor () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Metrics.space3) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? colors.litGlyph : colors.tertiary)
                Text(contact.name)
                    .font(Font(isChosen ? Typography.bodyEmphasized : Typography.body))
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                Text(contact.source == .team ? HomeConversationStrings.sourceTeam : HomeConversationStrings.sourceConnection)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: Metrics.sidebarRowHeight)
        .accessibilityValue(isChosen ? "1" : "0")
        .accessibilityIdentifier("cmux.home.groupInfo.add.\(contact.id.rawValue)")
    }
}
