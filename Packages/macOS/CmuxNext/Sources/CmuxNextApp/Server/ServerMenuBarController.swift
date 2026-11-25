import AppKit
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextServer
import os

/// The Mac server's menu bar item (plans/cmux-next/server.md 3 and 14).
///
/// DEV and NIGHTLY prototype: the item shows a projection of `server.status`
/// (`LocalServerSource` in the App, `MockServerSource` in previews) on the server card page
/// (webviews/src/pages/server-cards/server): the panel, Health and the pairing code in the item's
/// popover; Add Server is a native card (``AddServerDialog``). The item owns no server state: every
/// change is an intent to the source, through one ``ServerModel`` and its ``ServerPageProvider``.
@MainActor
final class ServerMenuBarController: NSObject {
    /// The popover's routes on the server card page.
    enum Route: String {
        case panel = "server-panel"
        case health = "server-health"
        case pairing = "server-pairing"
    }

    private var item: NSStatusItem?
    private var popover: ServerPanelPopover?
    /// The model's page provider; its model's source runs while `running` (`hide()` stops it).
    private var provider: ServerPageProvider?
    private var running = false
    /// The native Add Server card, made on the first opening and kept.
    private var addServer: AddServerDialog?
    /// The native Pair Another Machine card, made on its first opening (nil without the App's services).
    private lazy var invite: PairInviteDialog? = makeInvite()
    private let makeInvite: @MainActor () -> PairInviteDialog?
    /// Makes the Add Server card on the item's model (the App's sets its person check).
    private let makeAddServer: @MainActor (ServerModel) -> AddServerDialog
    /// Makes the model's source: the cloud pairing source in the App, the
    /// mock alone in previews and tests. Nil once the App's services are gone.
    private let makeSource: @MainActor () -> (any ServerSource)?
    /// The QR code of a payload as a PNG data URL.
    private let qr: (String) -> String?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.server-menu")

    init(makeSource: @escaping @MainActor () -> (any ServerSource)? = { MockServerSource(scenario: .healthyMac) },
         makeAddServer: @escaping @MainActor (ServerModel) -> AddServerDialog = { AddServerDialog(model: $0) },
         makeInvite: @escaping @MainActor () -> PairInviteDialog? = { nil }, qr: @escaping (String) -> String? = { _ in nil }) {
        self.makeSource = makeSource
        self.makeAddServer = makeAddServer
        self.makeInvite = makeInvite
        self.qr = qr
        super.init()
    }

    var isShown: Bool { item != nil }

    /// Puts the item in the menu bar (idempotent).
    func show() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage.icon(.machineRemote, size: 16)
            image.accessibilityDescription = String(localized: "server.menuBar.accessibility", defaultValue: "cmux server", table: "Server", bundle: .module.inAppLanguage)
            button.image = image
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        item = statusItem
    }

    /// Removes the item and closes its popover and cards (Add Server; an open invite's session ends).
    func hide() {
        popover?.close()
        addServer?.close()
        invite?.close()
        if running { provider?.model.stop() }
        running = false
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Opens `route` under the item. User-initiated only (palette or click).
    func open(_ route: Route) {
        show()
        guard let button = item?.button, let provider = currentProvider() else {
            return Self.logger.fault("server menu: no source (the App's services are gone)")
        }
        popover = popover ?? ServerPanelPopover(provider: provider)
        guard let popover else { return Self.logger.fault("server menu: the server card page is missing from the bundle") }
        popover.show(route: route.rawValue, under: button)
    }

    /// Shows the Add Server card near the top center of the front cmux window, on every Space and
    /// over full screen; it puts nothing in the menu bar. Opened by hand (`code` nil) it takes the
    /// keys for the code field; a code that arrived from outside (a pairing link, a script without
    /// the words) shows without taking them, so the person's typing goes on until they click the card.
    func openAddServer(code: String? = nil) {
        guard let provider = currentProvider() else { return Self.logger.fault("server card: no source (the App's services are gone)") }
        if let code { provider.model.beginApproval(code: code) } else { provider.model.beginApproval() }
        addServer = addServer ?? makeAddServer(provider.model)
        addServer?.open(over: Self.frontWindow(), takeKeys: code == nil)
    }

    /// Shows the native Pair Another Machine card top center over the front cmux window, with the keys, and mints a
    /// new invite (a card still showing a live one keeps it). Opened by a person only: the palette's person-only
    /// action and Add Device's hand-off.
    func openInvite() { invite?.open(over: Self.frontWindow()) }

    /// The cmux window the card belongs over: the main window, else the
    /// frontmost visible ordinary window.
    private static func frontWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover?.isShown == true {
            popover?.close()
        } else {
            open(.panel)
        }
    }

    /// The model and its page provider, made on the first opening; a source stopped by `hide()` starts
    /// again on the next.
    private func currentProvider() -> ServerPageProvider? {
        if provider == nil {
            guard let source = makeSource() else { return nil }
            provider = ServerPageProvider(model: ServerModel(source: source), personOnlyMessage: RefusalStrings.personOnlyFromPage, qr: qr)
        }
        if !running { provider?.model.start() }
        running = true
        return provider
    }
}
