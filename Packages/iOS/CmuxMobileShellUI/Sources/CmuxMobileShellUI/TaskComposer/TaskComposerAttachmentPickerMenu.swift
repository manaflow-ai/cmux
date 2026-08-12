#if os(iOS)
import CmuxMobileSupport
import CmuxAgentChatUI
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

    var body: some View {
        MobileAttachmentPickerButton(
            style: style == .circularPlus ? .circularPlus : .paperclip,
            isDisabled: isDisabled,
            choosePhotos: choosePhotos,
            chooseFiles: chooseFiles
        )
        .accessibilityIdentifier("MobileTaskComposerAttachmentButton")
    }
}
#endif
