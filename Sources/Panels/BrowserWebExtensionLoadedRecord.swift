import WebKit

@available(macOS 15.4, *)
struct BrowserWebExtensionLoadedRecord {
    let entryID: String
    let standardizedPath: String
    let context: WKWebExtensionContext
}
