public import Foundation

/// cmux-page:// first-party pages for Chromium tabs. The app sets the checked
/// table (CmuxNextApp `FirstPartyPageSchemes`) before Chromium starts;
/// `CEFRuntime` hands each entry to `cmux_shim_page_scheme_add_first_party`
/// when it initializes CEF. The shim refuses a reserved (`cmux.`) id on any
/// other path.
@MainActor
public struct CEFPageSchemes {
    public init() {}
    /// A first-party page: its bundled resource root and its own
    /// Content-Security-Policy (the page's `PageCSP` header; the shim's
    /// default `default-src 'self'` would block its inline module scripts).
    public struct Entry: Equatable, Sendable {
        public var root: URL
        public var csp: String
        public init(root: URL, csp: String) {
            self.root = root
            self.csp = csp
        }
    }

    /// Page id (`cmux.agent`) to its entry.
    public static var firstParty: [String: Entry] = [:]
}
