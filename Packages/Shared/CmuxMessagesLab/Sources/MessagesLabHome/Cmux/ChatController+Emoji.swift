// cmux: the emoji button beside the message box. Not a vendored file.
import AppKit

extension ChatController {
    func showEmojiPicker() {
        focusCompose()
        openEmojiPalette()
    }
}
