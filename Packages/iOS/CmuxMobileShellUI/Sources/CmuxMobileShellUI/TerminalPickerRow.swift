import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalPickerRow: View {
    let snapshot: TerminalPickerRowSnapshot
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let deleteTerminal: (MobileTerminalPreview.ID) -> Void

    var body: some View {
        Button {
            selectTerminal(snapshot.id)
        } label: {
            Label(
                snapshot.name,
                systemImage: snapshot.isSelected ? "checkmark.circle.fill" : "terminal"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if snapshot.canDelete {
                Button(role: .destructive) {
                    deleteTerminal(snapshot.id)
                } label: {
                    Label(L10n.string("mobile.common.delete", defaultValue: "Delete"), systemImage: "trash")
                }
                .tint(.red)
                .accessibilityIdentifier("MobileTerminalDeleteButton-\(snapshot.id.rawValue)")
            }
        }
        .accessibilityIdentifier("MobileTerminalMenuItem-\(snapshot.id.rawValue)")
    }
}
