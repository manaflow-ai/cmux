#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Shared attachment-source menu rendered by classic and minimal composers.
struct TaskComposerAttachmentPickerMenu: View {
    enum Style {
        case circularPlus
        case paperclip
    }

    let style: Style
    let isDisabled: Bool
    let choosePhotos: () -> Void
    let chooseFiles: () -> Void
    let pasteAttachments: () -> Void

    var body: some View {
        Menu {
            Button(action: choosePhotos) {
                Label(
                    L10n.string(
                        "mobile.taskComposer.attachments.photoLibrary",
                        defaultValue: "Photo Library"
                    ),
                    systemImage: "photo.on.rectangle"
                )
            }
            Button(action: chooseFiles) {
                Label(
                    L10n.string(
                        "mobile.taskComposer.attachments.chooseFiles",
                        defaultValue: "Choose Files"
                    ),
                    systemImage: "folder"
                )
            }
            Button(action: pasteAttachments) {
                Label(
                    L10n.string(
                        "mobile.taskComposer.attachments.paste",
                        defaultValue: "Paste"
                    ),
                    systemImage: "doc.on.clipboard"
                )
            }
        } label: {
            switch style {
            case .circularPlus:
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            case .paperclip:
                Image(systemName: "paperclip")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.attachments.add",
            defaultValue: "Add Attachment"
        ))
        .accessibilityIdentifier("MobileTaskComposerAttachmentButton")
    }
}
#endif
