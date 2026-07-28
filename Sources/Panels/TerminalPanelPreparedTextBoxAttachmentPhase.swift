enum TerminalPanelPreparedTextBoxAttachmentPhase {
    case preparing
    case prepared(
        TextBoxPreparedFileAttachment,
        TerminalImageTransferTarget
    )
    case uploading(
        TextBoxPreparedFileAttachment,
        TerminalImageTransferOperation
    )
    case uploaded(
        TextBoxPreparedFileAttachment,
        remotePath: String
    )
    case failed(TextBoxPreparedFileAttachment?)
}
