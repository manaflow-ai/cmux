public import CmuxBrowser
public import CoreGraphics
public import Foundation
public import Observation

/// The extension side of one Chromium page: its toolbar actions, the open
/// action popup, and the page as a target for extension calls.
///
/// The Chromium page adapter owns one and forwards ``BrowserExtensionHosting``
/// to it. Toolbar UI reads ``actions`` and calls ``run(_:anchorX:width:)``
/// with the button's frame so Chromium hangs the popup below it.
@MainActor
@Observable
public final class CEFExtensionPageSupport: CEFExtensionTab, BrowserExtensionHosting {
    /// The icon size requested from Chromium: the 22 pt toolbar button at 2x.
    public static let iconPixels: Int32 = 44

    /// The page's cmux browser profile.
    public let profileID: UUID
    /// The page's toolbar actions, in Chromium's toolbar order.
    public private(set) var actions: [BrowserExtensionAction] = []
    /// The extension whose popup is open, if any.
    public private(set) var openPopup: String?
    /// Runs a requested action from the toolbar (anchored to its button, or
    /// to the Extensions button when unpinned). Set by the toolbar; without
    /// it, ``requestExtensionAction(_:)`` anchors at the page's leading edge.
    @ObservationIgnored public var onActionRequested: (@MainActor (String) -> Void)?

    @ObservationIgnored private unowned let stores: CEFExtensionStores
    @ObservationIgnored private let browserID: @MainActor () -> Int32?
    @ObservationIgnored private var pendingAction: (id: String, x: Int32, width: Int32)?

    /// Creates the extension side of a page and registers it with `stores`.
    ///
    /// - Parameters:
    ///   - profileID: The page's cmux browser profile.
    ///   - stores: The engine's extension stores.
    ///   - browserID: The page's Chromium browser id, nil until created.
    public init(profileID: UUID, stores: CEFExtensionStores, browserID: @escaping @MainActor () -> Int32?) {
        self.profileID = profileID
        self.stores = stores
        self.browserID = browserID
        // The stores hold pages weakly and drop released ones.
        stores.register(self)
    }

    // MARK: CEFExtensionTab

    public var cefBrowserID: Int32? { browserID() }

    /// The fork's window id of the page (0 while unknown).
    var windowID: Int32 { cefBrowserID.map { stores.windowID(browser: $0) } ?? 0 }

    public func requestExtensionAction(_ extensionID: String) {
        if let onActionRequested {
            onActionRequested(extensionID)
        } else {
            _ = run(extensionID, anchorX: 0, width: 1)
        }
    }

    // MARK: BrowserExtensionHosting

    public var extensionStore: BrowserExtensionStore { stores.store(for: profileID) }
    public var extensionTab: any BrowserExtensionTab { self }
    public var extensionActions: [BrowserExtensionAction] { actions }

    // MARK: Actions

    /// Re-reads the page's toolbar actions.
    public func refreshActions() {
        guard let browser = cefBrowserID,
              let json = stores.extensionCalls.actions(browser: browser, iconPixels: Self.iconPixels) else { return }
        let next = BrowserExtensionAction.decodeList(json)
        if next != actions { actions = next }
    }

    /// The page's Chromium browser now exists: read actions and run a click that came first.
    public func browserCreated() {
        refreshActions()
        if let pending = pendingAction {
            pendingAction = nil
            _ = run(pending.id, anchorX: pending.x, width: pending.width)
        }
    }

    /// Runs an extension's toolbar action; its popup hangs below
    /// `anchorX ..< anchorX + width` (page view points from the leading edge).
    ///
    /// - Returns: False when Chromium refused; true when it ran or will run once the page exists.
    @discardableResult
    public func run(_ id: String, anchorX: Int32, width: Int32) -> Bool {
        guard let browser = cefBrowserID else {
            pendingAction = (id, anchorX, max(width, 1))
            return true
        }
        let ran = stores.extensionCalls.runAction(browser: browser, id: id, x: anchorX, width: max(width, 1))
        if ran, actions.first(where: { $0.id == id })?.hasPopup == true { openPopup = id }
        return ran
    }

    /// Run with a toolbar button frame in page-view coordinates.
    @discardableResult
    public func run(_ id: String, anchor: CGRect) -> Bool {
        run(id, anchorX: Int32(clamping: Int(anchor.minX.rounded())), width: Int32(clamping: Int(anchor.width.rounded())))
    }

    /// Closes the open action popup.
    public func hidePopup() {
        guard let browser = cefBrowserID, let open = openPopup else { return }
        stores.extensionCalls.hidePopup(browser: browser, id: open)
        openPopup = nil
    }

    /// Chromium's own action context menu at a screen point (AppKit coordinates, bottom-left origin).
    ///
    /// - Parameters:
    ///   - id: The extension.
    ///   - point: The point in AppKit screen coordinates.
    ///   - primaryScreenHeight: The primary screen's height (Chromium's screen origin is its top-left).
    public func showActionMenu(_ id: String, atScreenPoint point: CGPoint, primaryScreenHeight: CGFloat) {
        guard let browser = cefBrowserID else { return }
        stores.extensionCalls.showActionMenu(
            browser: browser, id: id,
            x: Int32(clamping: Int(point.x.rounded())),
            y: Int32(clamping: Int((primaryScreenHeight - point.y).rounded()))
        )
    }

    /// Chromium reported that the popup closed.
    func popupClosed() {
        openPopup = nil
        refreshActions()
    }
}
