import CmuxBrowser
import Foundation

// App-side localization seam for the browser download types relocated into
// CmuxBrowser. `String(localized:)` must resolve in the app bundle (the package
// bundle lacks the .xcstrings catalog), so the localized fallback filename is
// resolved here and injected through each type's package initializer. These
// no-argument conveniences keep every existing `BrowserDownloadFilenameResolver()`
// / `BrowserDownloadDelegate()` call site byte-identical.

extension BrowserDownloadFilenameResolver {
    /// Create a resolver whose fallback filename is the app-localized "download".
    init() {
        self.init(defaultFilename: String(localized: "browser.download.defaultFilename", defaultValue: "download"))
    }
}

extension BrowserDownloadDelegate {
    /// Create a download delegate whose fallback filename is the app-localized "download".
    convenience init() {
        self.init(defaultFilename: String(localized: "browser.download.defaultFilename", defaultValue: "download"))
    }
}
