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
        /// First path components the page host answers (the page's dynamic prefixes, `__patch`):
        /// Chromium asks the tab's ``CEFTab/pageResources`` for every request under one and never
        /// serves a file there.
        public var dynamicPrefixes: [String]
        /// The file `cmux-page://<id>/` serves (`index.html`, or a shared build's own page,
        /// `diff-page.html`).
        public var entry: String
        public init(root: URL, csp: String, dynamicPrefixes: [String] = [], entry: String = "index.html") {
            self.root = root
            self.csp = csp
            self.dynamicPrefixes = dynamicPrefixes
            self.entry = entry
        }
    }

    /// Page id (`cmux.agent`) to its entry.
    public static var firstParty: [String: Entry] = [:]

    /// One document-start script of the page host (fork API 29), from CmuxNextPages
    /// `ChromiumPageHostBridge.rendererScripts`: the App hands them to its ``CEFEngine``, and
    /// `CEFRuntime` installs them once for every browser with every tab's document scripts
    /// (`CEFDocumentScripts`). They post on ``hostChannel`` in ``hostWorld``.
    public struct HostScript: Equatable, Sendable {
        /// The isolated world it runs in; "" for the page's own world.
        public var world: String
        public var source: String
        /// Every frame; false for the main frame only.
        public var allFrames: Bool
        public init(world: String, source: String, allFrames: Bool) {
            self.world = world
            self.source = source
            self.allFrames = allFrames
        }
    }

    /// The page channel a cmux page's host script posts its calls on (renderer paths).
    nonisolated public static let hostChannel = "cmuxPageHost"
    /// The isolated world ``hostChannel`` lives in: the first-paint world, which every main frame
    /// on renderer paths has already, so the page host makes no extra world in a web page.
    nonisolated public static let hostWorld = BrowserFirstPaintScript.world
    /// The largest page host post accepted (CmuxNextPages `ChromiumPageHostBridge.maximumEnvelopeBytes`).
    nonisolated public static let hostMaxPayloadBytes = 2 * (4 << 20) + 64 * 1024
}
