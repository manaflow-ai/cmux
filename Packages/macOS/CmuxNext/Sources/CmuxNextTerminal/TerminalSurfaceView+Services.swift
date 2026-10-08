public import AppKit

// MARK: - Services (cx-k9go)

/// The terminal's selection is a Services requestor, as in a text view: a
/// right-click on selected text lists the system services that take text
/// (AppKit adds them to the context menu), and the Services menu in the app
/// menu offers them too. Nothing is ever written back into the terminal.
extension TerminalSurfaceView: NSServicesMenuRequestor {
    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                        returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let sendType, Self.serviceTypes.contains(sendType), hasSelection { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(where: Self.serviceTypes.contains), let text = accessibilitySelectedText(), !text.isEmpty else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    /// Plain text only: the selection has no styles or files.
    static let serviceTypes: Set<NSPasteboard.PasteboardType> = [.string, NSPasteboard.PasteboardType("public.utf8-plain-text")]
}
