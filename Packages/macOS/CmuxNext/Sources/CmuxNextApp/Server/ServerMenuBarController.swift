import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextServer
import CmuxNextWakeups
import os

/// The Mac server's menu bar item (plans/cmux-next/server.md 3 and 14).
///
/// DEV and NIGHTLY prototype: the item shows a projection of `server.status`
/// (`LocalServerSource` in the App, `MockServerSource` in previews); the panel,
/// pairing and health variants follow the Debug Settings switches
/// (`server.panel.style`, `server.pairing.style`, `server.health.style`).
/// The item owns no server state: every change is an intent to the source.
@MainActor
final class ServerMenuBarController: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private var popover: NSPopover?
    /// The floating Add Server card (u3849: pairing is not a menu bar popover).
    private var card: AddServerCardPanel?
    private var model: ServerModel?
    /// Makes the model's source: the cloud pairing source in the App, the
    /// mock alone in previews and tests. Nil once the App's services are gone.
    private let makeSource: @MainActor () -> (any ServerSource)?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.server-menu")

    init(makeSource: @escaping @MainActor () -> (any ServerSource)? = { MockServerSource(scenario: .healthyMac) }) {
        self.makeSource = makeSource
        super.init()
    }

    var isShown: Bool { item != nil }

    /// Puts the item in the menu bar (idempotent).
    func show() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage.icon(.machineRemote, size: 16)
            image.accessibilityDescription = String(localized: "server.menuBar.accessibility", defaultValue: "cmux server", table: "Server", bundle: .module)
            button.image = image
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        item = statusItem
    }

    /// Removes the item and closes its popover.
    func hide() {
        popover?.close()
        popover = nil
        card?.orderOut(nil)
        card = nil
        model?.stop()
        model = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Opens `surface` under the item. User-initiated only (palette or click).
    /// Add Server is the floating card over the cmux window instead, and puts
    /// nothing in the menu bar.
    func open(_ surface: ServerSurface) {
        if surface == .approver { return openCard(code: nil) }
        show()
        guard let button = item?.button else { return }
        popover?.close()
        guard let model = currentModel() else {
            Self.logger.fault("server menu: no source (the App's services are gone)")
            return
        }
        let view = ServerHostView(model: model, surface: surface)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 320), height: max(size.height, 120)))
        let controller = NSViewController()
        controller.view = view
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentViewController = controller
        pop.contentSize = view.frame.size
        pop.delegate = self
        view.onDismiss = { [weak pop] in pop?.close() }
        popover = pop
        pop.show(relativeTo: CmuxPopoverAnchor.rect(in: button), of: button, preferredEdge: .minY)
    }

    /// Shows the Add Server card near the top center of the front cmux window,
    /// on every Space and over full screen. Opened by hand (`code` nil) it
    /// takes the keys for the code field; a code that arrived from outside
    /// (a pairing link, a script without the words) shows without taking
    /// them, so the user's typing goes on until they click the card.
    func openCard(code: String?) {
        guard let model = currentModel() else {
            Self.logger.fault("server card: no source (the App's services are gone)")
            return
        }
        if let code {
            model.beginApproval(code: code)
        } else {
            model.beginApproval()
        }
        let card = self.card.flatMap { $0.model === model ? $0 : nil } ?? AddServerCardPanel(model: model)
        self.card = card
        card.present(over: Self.frontWindow(), takeKeys: code == nil)
    }

    /// The cmux window the card belongs over: the main window, else the
    /// frontmost visible ordinary window.
    private static func frontWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover?.isShown == true {
            popover?.close()
        } else {
            open(.panel(nil))
        }
    }

    /// NSPopover documents no thread for its delegate: inline on main, a hop from anywhere else.
    nonisolated func popoverDidClose(_ notification: Notification) {
        MainDelivery().run { self.popover = nil }
    }

    private func currentModel() -> ServerModel? {
        if let model { return model }
        guard let source = makeSource() else { return nil }
        let next = ServerModel(source: source)
        next.start()
        model = next
        return next
    }
}
