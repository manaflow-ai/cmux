import GhosttyNextKit

extension GhosttyRuntime {
    /// cmux has no link preview of its own: Ghostty's `mouse_over_link` report is how it knows
    /// which link Ghostty found under the pointer (``TerminalLinkPointer`` underlines and opens
    /// only links Ghostty does not find). With `link-previews = false` or `osc8` Ghostty reports
    /// no regex link, so cmux would underline Ghostty's links a second time and take their clicks.
    /// Loaded after the user's files; `link-previews` is not a setting cmux offers (GhosttySupport).
    static let linkReportLine = "link-previews = true"

    static func loadLinkReports(into config: ghostty_config_t) {
        linkReportLine.withCString { ghostty_config_load_string(config, $0, UInt(linkReportLine.utf8.count), "cmux-next") }
    }
}
