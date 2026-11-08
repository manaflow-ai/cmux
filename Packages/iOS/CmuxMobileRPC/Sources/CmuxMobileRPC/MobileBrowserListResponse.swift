import CMUXMobileCore
import Foundation

/// Typed `mobile.browser.list` result.
struct MobileBrowserListResponse: Decodable, Sendable {
    /// Discovered browser panels.
    let panels: [MobileBrowserPanelDescriptor]

    /// Decodes a browser-list result.
    static func decode(_ data: Data) throws -> MobileBrowserListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
