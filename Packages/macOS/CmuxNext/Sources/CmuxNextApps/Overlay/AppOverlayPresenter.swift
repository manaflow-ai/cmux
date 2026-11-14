public import AppKit
import CmuxNextCompat
public import CmuxNextDesign

/// An app's overlay (`presentation.overlay`): its `cmux.pane/1` scene in a glass card over the
/// window, centered, over the window's scrim. Only the person opens one: ``open(_:in:origin:)``
/// refuses any origin but `user`, and the supervisor refuses the mount the same way
/// (`apps/overlay.rs`, `apps.overlay_gesture`), so an app, a script, the CLI or an agent never
/// floats a panel in front of the person. Escape or a click outside the card closes it. One
/// overlay per window: opening another closes the first.
///
/// Hot reload: a saved script or manifest restarts the app's host and the supervisor remounts the
/// open overlay, so its scene redraws in place; a manifest that changes the overlay's size resizes
/// the card, and one that drops the overlay (or hides or disables the app) closes it.
@MainActor
public final class AppOverlayPresenter {
    /// Why an overlay did not open.
    public enum Refusal: Error, Equatable, Sendable {
        /// Not the person's own gesture.
        case gesture
        /// The app is not installed, visible, or declares no overlay with a scene.
        case undeclared
        /// No window to show it in.
        case noWindow

        public var message: String {
            switch self {
            case .gesture: AppsStrings.overlayGesture
            case .undeclared: AppsStrings.overlayUndeclared
            case .noWindow: AppsStrings.overlayNoWindow
            }
        }
    }

    /// One open overlay.
    private struct Shown {
        let appID: String
        let mount: AppMount
        let card: NSView
        let handle: OverlayHandle
        let watch: Task<Void, Never>
        let clickMonitor: Any?
    }

    private let client: AppsClient
    private var shown: [ObjectIdentifier: Shown] = [:]

    public init(client: AppsClient) {
        self.client = client
    }

    /// The app whose overlay `window` shows, if any.
    public func openApp(in window: NSWindow) -> String? { shown[ObjectIdentifier(window)]?.appID }

    /// The overlay's mount in `window` (tests, `apps.views`).
    public func mount(in window: NSWindow) -> AppMount? { shown[ObjectIdentifier(window)]?.mount }

    /// The apps whose overlay the palette offers ("Open <App> Overlay"), with the row's title:
    /// each visible app that declares an overlay with a scene. Follows the apps list, so a saved
    /// manifest adds or drops its row.
    public var offered: [(app: String, title: String)] {
        client.apps.filter { Self.refusal($0, origin: .user) == nil }.map { record in
            (record.id, AppsStrings.overlayOpen((record.manifest.presentation?.overlay?.title ?? record.manifest.name).resolved()))
        }
    }

    /// Whether `origin` may open `record`'s overlay: nil when it may, else why not (pure).
    public nonisolated static func refusal(_ record: AppRecord?, origin: AppOrigin) -> Refusal? {
        guard origin == .user else { return .gesture }
        guard let record, AppMountSurface.overlay.implementation(of: record, id: nil) != nil else { return .undeclared }
        return nil
    }

    /// The card's size: the manifest's, capped to `bounds` less a margin on each side (pure).
    public nonisolated static func cardSize(_ overlay: AppPresentation.Overlay, in bounds: CGSize, margin: CGFloat) -> CGSize {
        CGSize(width: max(0, min(overlay.size.width, bounds.width - 2 * margin)),
               height: max(0, min(overlay.size.height, bounds.height - 2 * margin)))
    }

    /// Opens `app`'s overlay in `window` for the person's gesture (`origin` user).
    public func open(_ app: String, in window: NSWindow, origin: AppOrigin) throws(Refusal) {
        let record = client.app(app)
        if let refusal = Self.refusal(record, origin: origin) { throw refusal }
        guard let record, let overlay = record.manifest.presentation?.overlay,
              let implementation = AppMountSurface.overlay.implementation(of: record, id: nil) else { throw .undeclared }
        guard window.contentView != nil else { throw .noWindow }
        close(in: window)
        let mount = client.mount(app, implementation: implementation, surface: AppMountSurface.overlay.rawValue, origin: .user)
        let scene = mount.makeView()
        let card = Glass.makeOverlayPanel(content: scene)
        card.translatesAutoresizingMaskIntoConstraints = true
        card.setAccessibilityIdentifier("cmux.app.overlay")
        card.setAccessibilityLabel((overlay.title ?? record.manifest.name).resolved())
        card.setFrameSize(Self.cardSize(overlay, in: window.contentView?.bounds.size ?? .zero, margin: Metrics.space5))
        let handle = WindowOverlayHost.host(for: window).present(card, options: .dialog(dimsContent: true))
        let key = ObjectIdentifier(window)
        handle.onDismiss = { [weak self] in self?.ended(key) }
        handle.onWindowGeometryChange = { [weak self, weak window] in
            guard let self, let window, let overlay = self.client.app(app)?.manifest.presentation?.overlay else { return }
            self.resize(in: window, to: overlay)
        }
        shown[key] = Shown(appID: app, mount: mount, card: card, handle: handle,
                           watch: watch(app, in: window), clickMonitor: clickOutsideMonitor(card: card, window: window))
    }

    /// Closes the overlay of `window`, if one shows.
    public func close(in window: NSWindow) {
        shown[ObjectIdentifier(window)]?.handle.dismiss()
    }

    /// Follows the app's record (the list an `apps-changed` brings): a new size resizes the card;
    /// an app that no longer shows an overlay closes it.
    private func watch(_ app: String, in window: NSWindow) -> Task<Void, Never> {
        let client = client
        // task-owner: the open overlay (cancelled in `ended`); event-driven (Observation)
        return Task { [weak self, weak window] in
            for await overlay in ObservationStream({ client.app(app).flatMap { record in
                AppMountSurface.overlay.implementation(of: record, id: nil) == nil ? nil : record.manifest.presentation?.overlay
            } }) {
                guard let self, let window else { return }
                guard let overlay else {
                    close(in: window)
                    return
                }
                resize(in: window, to: overlay)
            }
        }
    }

    private func resize(in window: NSWindow, to overlay: AppPresentation.Overlay) {
        guard let entry = shown[ObjectIdentifier(window)] else { return }
        let size = Self.cardSize(overlay, in: window.contentView?.bounds.size ?? .zero, margin: Metrics.space5)
        guard entry.card.frame.size != size else { return }
        entry.card.setFrameSize(size)
        entry.handle.update(anchor: NSRect(origin: .zero, size: window.contentView?.bounds.size ?? .zero))
    }

    /// A click anywhere but the card closes the overlay (Escape closes it through the dialog).
    private func clickOutsideMonitor(card: NSView, window: NSWindow) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak card, weak window] event in
            guard let self, let card, let window else { return event }
            let inside = event.window === card.window && card.convert(card.bounds, to: nil).contains(event.locationInWindow)
            if !inside, event.window === window || event.window?.parent === window || event.window === card.window {
                close(in: window)
            }
            return event
        }
    }

    private func ended(_ key: ObjectIdentifier) {
        guard let entry = shown.removeValue(forKey: key) else { return }
        entry.watch.cancel()
        if let monitor = entry.clickMonitor { NSEvent.removeMonitor(monitor) }
        client.unmount(entry.mount)
    }
}
