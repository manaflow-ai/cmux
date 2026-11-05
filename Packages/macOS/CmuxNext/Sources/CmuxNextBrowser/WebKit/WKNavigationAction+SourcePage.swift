import Foundation
import WebKit

extension WKNavigationAction {
    /// The origin of the frame the navigation came from, as a URL (nil when
    /// opaque or unknown): the page whose link was clicked, even while the
    /// web view's `url` already shows the page it is loading.
    var sourcePage: URL? {
        guard let origin = (sourceFrame as WKFrameInfo?)?.securityOrigin, !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        var page = URLComponents()
        page.scheme = origin.protocol
        page.host = origin.host
        if origin.port != 0 { page.port = origin.port }
        return page.url
    }
}
