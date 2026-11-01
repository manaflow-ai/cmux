import Foundation

public extension ControlCall {
    /// The terminal `params[key]` names (`terminal_id`, the caller's `CMUX_TUI_TERMINAL_ID`) and
    /// the tab that shows it, for a request that opens something beside its caller's terminal
    /// (`browser.open_link`). `terminal` is nil when the param is omitted, null or empty (the
    /// focused pane is meant); `tab` is nil too when no tab shows the named terminal (a closed or
    /// stale terminal, or another session's), which the caller must not read as the focused pane
    /// (#29224). A value that is not a string is `invalid_params`.
    func terminalTab(_ key: String = "terminal_id") throws -> (terminal: String?, tab: String?) {
        guard let value = params[key], !value.isNull else { return (nil, nil) }
        guard let text = value.stringValue else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", key))
        }
        guard !text.isEmpty else { return (nil, nil) }
        return (text, snapshot.topology.tabID(ofTerminal: text))
    }
}
