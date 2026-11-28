public import AppKit

// The selection as a Services requestor (TerminalServices, cx-k9go).
extension TerminalSurfaceView: NSServicesMenuRequestor {
    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        TerminalServices.accepts(sendType, returnType, hasSelection: hasSelection) ? self : super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        TerminalServices.write(accessibilitySelectedText(), to: pboard, types: types)
    }
}
