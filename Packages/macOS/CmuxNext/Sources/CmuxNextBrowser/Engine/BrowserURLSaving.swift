public import Foundation

/// A page that downloads an address into a file the person chose, with its
/// own session (cookies included). WebKit does; Chromium will once the shim
/// has a download API (until then its menu hands Save Link As back to
/// Chromium, `BrowserEngineMenuCommand`).
public protocol BrowserURLSaving: AnyObject {
    func save(_ url: URL, to destination: URL)
}
