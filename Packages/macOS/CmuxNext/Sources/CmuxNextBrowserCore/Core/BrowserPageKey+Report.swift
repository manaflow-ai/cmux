extension BrowserPageKey {
    /// A key a WebKit page reported it left unhandled (``BrowserPageKeyReportScript``): one ASCII
    /// letter, uppercase for Shift. Untrusted page data: anything else is nil.
    public init?(reported payload: String) {
        guard payload.unicodeScalars.count == 1, let scalar = payload.unicodeScalars.first else { return nil }
        switch scalar {
        case "a"..."z": self.init(character: payload, shift: false)
        case "A"..."Z": self.init(character: payload, shift: true)
        default: return nil
        }
    }
}
