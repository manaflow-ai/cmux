public import AppKit

// The page's ACP inspector, from the host side: the palette toggles it
// (`agentPane.toggleInspector`), and its Export saves through a save panel
// (`pane.saveLog`).
extension AgentPaneView {
    /// Opens the inspector when `open` is true, closes it when false, and
    /// toggles it when nil. A page that has not loaded its bridge yet
    /// ignores it.
    public func toggleInspector(open: Bool? = nil) {
        evaluateScript(Self.inspectorScript(open: open))
    }

    /// The script that calls the page's `cmuxAcpmuxBridge.toggleInspector`.
    static func inspectorScript(open: Bool?) -> String {
        let argument = open.map { $0 ? "true" : "false" } ?? ""
        return "window.cmuxAcpmuxBridge?.toggleInspector?.(\(argument));"
    }
}
