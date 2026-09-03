import AppKit
import Foundation

/// Engine-neutral UI delegate. Method shape mirrors `WKUIDelegate`.
/// Backends translate to the engine's equivalent.
@MainActor
public protocol CmuxUIDelegate: AnyObject {
    /// Called when the page requests a new browser view (e.g. `window.open`,
    /// `target="_blank"` with cmd-click). Return `nil` to suppress; return a
    /// view to host the new content (the view should be displayed in a new
    /// window or tab by the host).
    func browserView(
        _ view: CmuxBrowserView,
        createBrowserViewWith configuration: CmuxBrowserConfiguration,
        for navigationAction: CmuxNavigationAction,
        windowFeatures: CmuxWindowFeatures
    ) -> CmuxBrowserView?

    func browserViewDidClose(_ view: CmuxBrowserView)

    func browserView(
        _ view: CmuxBrowserView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping () -> Void
    )

    func browserView(
        _ view: CmuxBrowserView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    )

    func browserView(
        _ view: CmuxBrowserView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping (String?) -> Void
    )

    func browserView(
        _ view: CmuxBrowserView,
        runOpenPanelWith parameters: CmuxOpenPanelParameters,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    )

    func browserView(
        _ view: CmuxBrowserView,
        contextMenuConfigurationForElement element: CmuxContextMenuElementInfo,
        completionHandler: @escaping (NSMenu?) -> Void
    )
}

public extension CmuxUIDelegate {
    func browserView(
        _ view: CmuxBrowserView,
        createBrowserViewWith configuration: CmuxBrowserConfiguration,
        for navigationAction: CmuxNavigationAction,
        windowFeatures: CmuxWindowFeatures
    ) -> CmuxBrowserView? {
        nil
    }

    func browserViewDidClose(_ view: CmuxBrowserView) {}

    func browserView(
        _ view: CmuxBrowserView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func browserView(
        _ view: CmuxBrowserView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func browserView(
        _ view: CmuxBrowserView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }

    func browserView(
        _ view: CmuxBrowserView,
        runOpenPanelWith parameters: CmuxOpenPanelParameters,
        initiatedByFrame frame: CmuxFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }

    func browserView(
        _ view: CmuxBrowserView,
        contextMenuConfigurationForElement element: CmuxContextMenuElementInfo,
        completionHandler: @escaping (NSMenu?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct CmuxWindowFeatures: Sendable {
    public let menuBarVisibility: Bool?
    public let statusBarVisibility: Bool?
    public let toolbarsVisibility: Bool?
    public let allowsResizing: Bool?
    public let x: CGFloat?
    public let y: CGFloat?
    public let width: CGFloat?
    public let height: CGFloat?

    public init(
        menuBarVisibility: Bool? = nil,
        statusBarVisibility: Bool? = nil,
        toolbarsVisibility: Bool? = nil,
        allowsResizing: Bool? = nil,
        x: CGFloat? = nil,
        y: CGFloat? = nil,
        width: CGFloat? = nil,
        height: CGFloat? = nil
    ) {
        self.menuBarVisibility = menuBarVisibility
        self.statusBarVisibility = statusBarVisibility
        self.toolbarsVisibility = toolbarsVisibility
        self.allowsResizing = allowsResizing
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CmuxOpenPanelParameters: Sendable {
    public let allowsMultipleSelection: Bool
    public let allowsDirectories: Bool

    public init(allowsMultipleSelection: Bool, allowsDirectories: Bool) {
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsDirectories = allowsDirectories
    }
}

public struct CmuxContextMenuElementInfo: Sendable {
    public let linkURL: URL?
    public let imageURL: URL?
    public let mediaURL: URL?

    public init(linkURL: URL?, imageURL: URL?, mediaURL: URL?) {
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.mediaURL = mediaURL
    }
}
