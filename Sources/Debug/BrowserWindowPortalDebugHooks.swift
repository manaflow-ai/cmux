#if DEBUG
import WebKit

@MainActor
var browserPortalTestWillForceHostedWebKitLayout: ((WKWebView) -> Void)?
#endif
