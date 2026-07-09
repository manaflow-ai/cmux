import CmuxSettings
import WebKit

@available(macOS 15.4, *)
struct BrowserWebExtensionLoadedRecord {
    let entry: BrowserWebExtensionEntry
    let standardizedPath: String
    let context: WKWebExtensionContext

    var entryID: String { entry.id }
}
