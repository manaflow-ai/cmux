public import Foundation

/// A page that downloads an address into a file the person chose, with its
/// own session (cookies included): WebKit through `WKDownload`, Chromium
/// through the shim's downloads (`CEFDownloads`).
public protocol BrowserURLSaving: AnyObject {
    func save(_ url: URL, to destination: URL)
}
