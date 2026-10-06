import AppKit
import CmuxNextServer

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
    private var model: ServerModel?
    /// Makes the model's source: the cloud pairing source in the App, the
    /// mock alone in previews and tests.
    private let makeSource: @MainActor () -> any ServerSource

    init(makeSource: @escaping @MainActor () -> any ServerSource = { MockServerSource(scenario: .healthyMac) }) {
        self.makeSource = makeSource
        super.init()
    }

    var isShown: Bool { item != nil }

    /// Puts the item in the menu bar (idempotent).
    func show() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: String(localized: "server.menuBar.accessibility", defaultValue: "cmux server", table: "Server", bundle: .module))
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        item = statusItem
    }

    /// Removes the item and closes its popover.
    func hide() {
        popover?.close()
        popover = nil
        model?.stop()
        model = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Opens `surface` under the item. User-initiated only (palette or click).
    func open(_ surface: ServerSurface) {
        show()
        guard let button = item?.button else { return }
        popover?.close()
        let model = currentModel()
        let view = ServerHostView(model: model, surface: surface)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 320), height: max(size.height, 120)))
        let controller = NSViewController()
        controller.view = view
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = controller
        pop.contentSize = view.frame.size
        pop.delegate = self
        view.onDismiss = { [weak pop] in pop?.close() }
        popover = pop
        pop.show(relativeTo: CmuxPopoverAnchor.rect(in: button), of: button, preferredEdge: .minY)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover?.isShown == true {
            popover?.close()
        } else {
            open(.panel(nil))
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { popover = nil }
    }

    private func currentModel() -> ServerModel {
        if let model { return model }
        let next = ServerModel(source: makeSource())
        next.start()
        model = next
        return next
    }
}
