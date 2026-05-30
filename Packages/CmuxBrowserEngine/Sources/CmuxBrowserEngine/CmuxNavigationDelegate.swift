import AppKit
import Foundation

/// Engine-neutral navigation delegate. Method shape mirrors
/// `WKNavigationDelegate`; backends translate.
@MainActor
public protocol CmuxNavigationDelegate: AnyObject {
    func browserView(
        _ view: CmuxBrowserView,
        decidePolicyFor navigationAction: CmuxNavigationAction,
        decisionHandler: @escaping (CmuxNavigationActionPolicy) -> Void
    )

    func browserView(
        _ view: CmuxBrowserView,
        decidePolicyFor navigationResponse: CmuxNavigationResponse,
        decisionHandler: @escaping (CmuxNavigationResponsePolicy) -> Void
    )

    func browserView(_ view: CmuxBrowserView, didStartProvisionalNavigation navigation: CmuxNavigation)
    func browserView(_ view: CmuxBrowserView, didCommit navigation: CmuxNavigation)
    func browserView(_ view: CmuxBrowserView, didFinish navigation: CmuxNavigation)
    func browserView(_ view: CmuxBrowserView, didFail navigation: CmuxNavigation, withError error: Error)
    func browserView(_ view: CmuxBrowserView, didFailProvisionalNavigation navigation: CmuxNavigation, withError error: Error)

    func browserView(
        _ view: CmuxBrowserView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    )

    func browserViewWebContentProcessDidTerminate(_ view: CmuxBrowserView)
}

// Default no-op implementations so adopters only override what they need.
public extension CmuxNavigationDelegate {
    func browserView(
        _ view: CmuxBrowserView,
        decidePolicyFor navigationAction: CmuxNavigationAction,
        decisionHandler: @escaping (CmuxNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func browserView(
        _ view: CmuxBrowserView,
        decidePolicyFor navigationResponse: CmuxNavigationResponse,
        decisionHandler: @escaping (CmuxNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func browserView(_ view: CmuxBrowserView, didStartProvisionalNavigation navigation: CmuxNavigation) {}
    func browserView(_ view: CmuxBrowserView, didCommit navigation: CmuxNavigation) {}
    func browserView(_ view: CmuxBrowserView, didFinish navigation: CmuxNavigation) {}
    func browserView(_ view: CmuxBrowserView, didFail navigation: CmuxNavigation, withError error: Error) {}
    func browserView(_ view: CmuxBrowserView, didFailProvisionalNavigation navigation: CmuxNavigation, withError error: Error) {}

    func browserView(
        _ view: CmuxBrowserView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func browserViewWebContentProcessDidTerminate(_ view: CmuxBrowserView) {}
}

public struct CmuxNavigation: Sendable, Hashable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public enum CmuxNavigationActionPolicy: Sendable {
    case cancel
    case allow
    case download
}

public enum CmuxNavigationResponsePolicy: Sendable {
    case cancel
    case allow
    case download
}

public struct CmuxNavigationAction: @unchecked Sendable {
    public enum NavigationType: Sendable {
        case linkActivated
        case formSubmitted
        case backForward
        case reload
        case formResubmitted
        case other
    }

    public let request: URLRequest
    public let sourceFrame: CmuxFrameInfo
    public let targetFrame: CmuxFrameInfo?
    public let navigationType: NavigationType
    public let modifierFlags: NSEvent.ModifierFlags
    public let buttonNumber: Int
    public let shouldPerformDownload: Bool

    public init(
        request: URLRequest,
        sourceFrame: CmuxFrameInfo,
        targetFrame: CmuxFrameInfo?,
        navigationType: NavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int,
        shouldPerformDownload: Bool
    ) {
        self.request = request
        self.sourceFrame = sourceFrame
        self.targetFrame = targetFrame
        self.navigationType = navigationType
        self.modifierFlags = modifierFlags
        self.buttonNumber = buttonNumber
        self.shouldPerformDownload = shouldPerformDownload
    }
}

public struct CmuxNavigationResponse: Sendable {
    public let response: URLResponse
    public let isForMainFrame: Bool
    public let canShowMIMEType: Bool

    public init(response: URLResponse, isForMainFrame: Bool, canShowMIMEType: Bool) {
        self.response = response
        self.isForMainFrame = isForMainFrame
        self.canShowMIMEType = canShowMIMEType
    }
}

public struct CmuxFrameInfo: Sendable {
    public let isMainFrame: Bool
    public let request: URLRequest
    public let securityOriginHost: String?
    public let securityOriginPort: Int?

    public init(
        isMainFrame: Bool,
        request: URLRequest,
        securityOriginHost: String?,
        securityOriginPort: Int?
    ) {
        self.isMainFrame = isMainFrame
        self.request = request
        self.securityOriginHost = securityOriginHost
        self.securityOriginPort = securityOriginPort
    }
}

