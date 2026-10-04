public import Foundation

/// cmux-page:// first-party pages for Chromium tabs. The app sets the checked
/// table (CmuxNextApp `FirstPartyPageSchemes`) before Chromium starts;
/// `CEFRuntime` hands each entry to `cmux_shim_page_scheme_add_first_party`
/// when it initializes CEF. The shim refuses a reserved (`cmux.`) id on any
/// other path.
@MainActor
public enum CEFPageSchemes {
    /// Page id (`cmux.agent`) to its bundled resource root.
    public static var firstPartyRoots: [String: URL] = [:]
}
