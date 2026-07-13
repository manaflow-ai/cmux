#if canImport(UIKit)
public import SwiftUI
import UIKit
public import WebKit
import CmuxMobileShellModel
import CmuxMobileSupport

/// Hosts the existing cmux React/Pierre diff renderer with a native file bridge.
public struct MobileDiffWebView: UIViewRepresentable {
    /// The observable document and file-selection state rendered by the view.
    public let state: MobileDiffState

    /// Creates a web-backed diff renderer bound to native diff state.
    /// - Parameter state: Shared state for the loaded diff and native selection.
    public init(state: MobileDiffState) {
        self.state = state
    }

    /// The UIKit/WebKit coordinator used by this representable.
    public typealias Coordinator = MobileDiffWebViewCoordinator

    /// Creates the coordinator that owns the WebKit bridge lifecycle.
    public func makeCoordinator() -> MobileDiffWebViewCoordinator {
        MobileDiffWebViewCoordinator(state: state)
    }

    /// Creates and configures the underlying web view.
    /// - Parameter context: SwiftUI representable context containing the coordinator.
    /// - Returns: A web view configured for the private mobile-diff scheme.
    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.patchHandler, forURLScheme: MobileDiffPatchSchemeHandler.scheme)
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.attach(webView)
        return webView
    }

    /// Applies current native state to the existing web view.
    /// - Parameters:
    ///   - webView: The web view created by ``makeUIView(context:)``.
    ///   - context: SwiftUI representable context containing the coordinator.
    public func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(state: state)
    }

    /// Detaches message handlers and pending work before SwiftUI releases the view.
    /// - Parameters:
    ///   - webView: The web view being dismantled.
    ///   - coordinator: The coordinator attached to the web view.
    public static
    func dismantleUIView(_ webView: WKWebView, coordinator: MobileDiffWebViewCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
        webView.navigationDelegate = nil
        coordinator.detach()
    }
}
#endif
