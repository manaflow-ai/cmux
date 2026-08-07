public import WebKit

/// Where the focus handler is registered and unregistered.
///
/// A seam rather than a direct `WKUserContentController` call, because absence is the security
/// property here and `WKUserContentController` cannot be asked what it holds. Without somewhere to
/// observe the registration, a test can only re-install and infer from the lack of a trap — which
/// passes just as happily when nothing was ever registered. This narrows to exactly the one handler
/// the bridge owns: it is not a general script-handler facility, and adding another capability means
/// designing that capability, not reusing this.
@MainActor
public protocol CustomSidebarFocusHandlerRegistering: AnyObject {
    /// Registers the bridge as the sole focus handler, replacing any current registration.
    ///
    /// - Parameter bridge: The handler to register.
    func installFocusHandler(_ bridge: CustomSidebarFocusBridge)

    /// Removes any focus handler registration.
    func removeFocusHandler()
}

/// Registers the focus handler on a real web view's content controller.
///
/// Holds the controller rather than the web view so the registry cannot reach anything else about
/// the page.
@MainActor
public final class CustomSidebarWebViewFocusHandlerRegistry: CustomSidebarFocusHandlerRegistering {
    private let userContentController: WKUserContentController

    /// Creates a registry over a web view's content controller.
    ///
    /// - Parameter userContentController: The content controller of the sidebar's web view.
    public init(userContentController: WKUserContentController) {
        self.userContentController = userContentController
    }

    public func installFocusHandler(_ bridge: CustomSidebarFocusBridge) {
        // `addScriptMessageHandler` traps on a duplicate name, and a sidebar's web view is reused
        // across source changes, so a removal always precedes an install.
        removeFocusHandler()
        userContentController.addScriptMessageHandler(
            bridge,
            contentWorld: CustomSidebarFocusBridge.contentWorld,
            name: CustomSidebarFocusBridge.handlerName
        )
    }

    public func removeFocusHandler() {
        userContentController.removeScriptMessageHandler(
            forName: CustomSidebarFocusBridge.handlerName,
            contentWorld: CustomSidebarFocusBridge.contentWorld
        )
    }
}
