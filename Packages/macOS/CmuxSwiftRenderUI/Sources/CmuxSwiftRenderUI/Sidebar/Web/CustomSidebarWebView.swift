import CmuxSwiftRender
import SwiftUI
import WebKit

/// Hosts an HTML custom sidebar in a transparent native `WKWebView`.
struct CustomSidebarWebView: NSViewRepresentable {
    let fileURL: URL
    let dataContext: [String: SwiftValue]
    let dispatch: SidebarActionDispatch
    let contentInsets: CustomSidebarContentInsets
    let colorScheme: ColorScheme

    func makeCoordinator() -> CustomSidebarWebViewCoordinator {
        CustomSidebarWebViewCoordinator(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            colorScheme: colorScheme
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            webView: webView,
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            colorScheme: colorScheme
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CustomSidebarWebViewCoordinator) {
        coordinator.dismantle(webView: webView)
    }
}
