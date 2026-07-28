import Foundation

struct TerminalPanelPendingTextBoxAttachmentRequest {
    let fileURL: URL
    var completions: [@MainActor (Bool) -> Void]
}
