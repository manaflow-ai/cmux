public import Foundation
public import WebKit
internal import os

/// The single native call a qualifying web sidebar may make: focus one workspace by id.
///
/// A page reaches it as a promise:
///
/// ```js
/// const reply = await window.webkit.messageHandlers
///     .cmuxSidebarFocusWorkspace
///     .postMessage({ v: 1, workspaceId: id })
/// // reply === { v: 1, status: 'focused' | 'not-found' | 'unavailable' }
/// ```
///
/// The bridge is registered only for a source that armed a ``CustomSidebarFocusScope``, so a public
/// page never sees the handler exist at all — `window.webkit.messageHandlers.cmuxSidebarFocusWorkspace`
/// is `undefined` there, which is the strongest form of "no". For an armed source, every message is
/// re-checked against the scope at dispatch time, because the handler outlives any single document.
///
/// Rejections are deliberately uniform. A malformed body and a page that navigated out of its scope
/// both reject the promise with the same opaque message, so the bridge cannot be used to probe which
/// guard tripped. The detail goes to the log instead, where the sidebar author can read it and a
/// hostile page cannot.
@MainActor
public final class CustomSidebarFocusBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The handler name a page posts to. Exactly one handler is registered, under this name.
    public static let handlerName = "cmuxSidebarFocusWorkspace"

    /// The content world the handler is registered in.
    ///
    /// `.page` rather than a private world: the point is for the sidebar's own page scripts to call
    /// it, and a private world would be invisible to them.
    public static let contentWorld: WKContentWorld = .page

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "CustomSidebarFocus")

    /// The one message the page ever sees for a refused request.
    private static let rejectionMessage = "cmux sidebar focus request rejected"

    private let scope: CustomSidebarFocusScope
    private let capability: CustomSidebarFocusCapability

    /// Creates a bridge for one armed source.
    ///
    /// - Parameters:
    ///   - scope: The armed source. Every dispatch is re-checked against it.
    ///   - capability: Performs the focus and reports what happened. A reference, not a closure, so
    ///     a remount that supplies a fresh closure replaces the one this bridge calls instead of
    ///     leaving it pinned to whichever closure existed at install time.
    public init(
        scope: CustomSidebarFocusScope,
        capability: CustomSidebarFocusCapability
    ) {
        self.scope = scope
        self.capability = capability
        super.init()
    }

    /// Resolves a message to a status, or `nil` when it must be rejected.
    ///
    /// Split out from the delegate callback so the whole decision is reachable from a test without
    /// manufacturing a `WKScriptMessage`, which has no public initializer.
    ///
    /// - Parameters:
    ///   - messageBody: The raw `postMessage` body.
    ///   - isMainFrame: Whether the sending frame is the main frame.
    ///   - frameOriginScheme: The sending frame's security-origin scheme.
    ///   - frameOriginHost: The sending frame's security-origin host.
    ///   - frameOriginPort: The sending frame's security-origin port.
    ///   - webViewURL: The web view's current URL.
    /// - Returns: The status to reply with, or `nil` to reject.
    public func resolve(
        messageBody: Any,
        isMainFrame: Bool,
        frameOriginScheme: String?,
        frameOriginHost: String?,
        frameOriginPort: Int?,
        webViewURL: URL?
    ) -> CustomSidebarFocusStatus? {
        guard scope.permitsDispatch(
            isMainFrame: isMainFrame,
            frameOriginScheme: frameOriginScheme,
            frameOriginHost: frameOriginHost,
            frameOriginPort: frameOriginPort,
            webViewURL: webViewURL
        ) else {
            CustomSidebarFocusBridge.logger.error(
                "custom sidebar focus request refused: sender is outside the armed source"
            )
            return nil
        }
        guard let request = CustomSidebarFocusRequest(messageBody: messageBody) else {
            CustomSidebarFocusBridge.logger.error(
                "custom sidebar focus request refused: body is not { v: 1, workspaceId: <uuid> }"
            )
            return nil
        }
        return capability.focus(request.workspaceID)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        let status = resolve(
            messageBody: message.body,
            isMainFrame: message.frameInfo.isMainFrame,
            frameOriginScheme: origin.protocol,
            frameOriginHost: origin.host,
            frameOriginPort: Int(origin.port),
            webViewURL: message.webView?.url
        )
        guard let status else {
            return (nil, CustomSidebarFocusBridge.rejectionMessage)
        }
        return (status.replyBody, nil)
    }
}
