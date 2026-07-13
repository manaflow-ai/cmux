#if os(iOS)
import SwiftUI
@preconcurrency import UIKit
@preconcurrency import WebKit

/// Full-size WKWebView configured for the bundled mobile diff surface.
struct MobileDiffWebView: UIViewRepresentable {
    let controller: MobileDiffWebViewController
    let service: MobileDiffRPCService
    let paths: [String]
    let layout: MobileDiffHostPage.Layout
    let theme: ColorScheme
    let title: String
    let onTooLargePaths: ([String]) -> Void

    func makeCoordinator() -> MobileDiffWebViewCoordinator {
        MobileDiffWebViewCoordinator(
            controller: controller,
            service: service,
            paths: paths,
            layout: layout,
            title: title,
            onTooLargePaths: onTooLargePaths
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.schemeHandler,
            forURLScheme: MobileDiffURLSchemeHandler.scheme
        )
        configuration.userContentController.add(
            context.coordinator,
            name: "cmuxMobileDiff"
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif

        controller.attach(webView)
        controller.updatePresentation(layout: layout, theme: theme)
        let pageURL = context.coordinator.schemeHandler.origin.appendingPathComponent("index.html")
        webView.load(URLRequest(url: pageURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        controller.updatePresentation(layout: layout, theme: theme)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: MobileDiffWebViewCoordinator) {
        coordinator.tearDown(webView: webView)
    }
}
#endif
