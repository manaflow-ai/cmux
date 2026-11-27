import Foundation
import WebKit

/// A validated app-session navigation and its isolated WebKit storage.
struct BrowserAppSessionNavigation {
    let request: URLRequest
    let websiteDataStore: WKWebsiteDataStore
    let generation: UInt64
    let authSessionGeneration: UInt64
}
