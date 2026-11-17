import Foundation

/// The widget ops of the app supervisor (`apps-store` `apps.widgets.*`, cmux-tui-core
/// `apps/widgets.rs`). The daemon owns the layout and the refresh budget; a client reads the
/// layout, sends a person's edits and says which tiles it shows.
extension AppsClient {
    /// The interface a widget implements.
    public static let widgetInterface = "cmux.widget/1"
    /// The mount context's `surface` for a widget tile.
    public static let widgetSurface = "widget"

    /// One widget op as the page asked it (`apps.widgets.list`, `apps.widgets.layout.edit`,
    /// `apps.widgets.meters`), its reply as the daemon wrote it; `origin` is `user` only for the
    /// person's own edit.
    public func widgets(_ op: String, args: AppJSON, origin: AppOrigin = .script) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        do throws(AppsTransportError) { return try await transport.storeCall(op, args: args, origin: origin) }
        catch { throw .refused(error) }
    }

    /// The widgets the person can place in `place` and the tiles placed there (`apps.widgets.list`).
    public func widgets(place: String) async throws(AppsClientError) -> AppWidgetCatalog {
        AppWidgetCatalog(reply: try await widgets("apps.widgets.list", args: ["place": .string(place)]), place: place)
    }

    /// Sends one layout edit from the person's gesture (`apps.widgets.layout.edit`, origin `user`)
    /// with a fresh idempotency key. Every client hears `apps-widgets-changed` once it is saved.
    public func editWidgets(place: String, _ edit: AppWidgetEdit) async throws(AppsClientError) {
        let args: AppJSON = ["place": .string(place), "edit": edit.json, "idempotency_key": .string(nextIdempotencyKey())]
        _ = try await widgets("apps.widgets.layout.edit", args: args, origin: .user)
    }

    /// Tells the supervisor whether a widget tile shows (`apps.widgets.visible`): a hidden tile gets
    /// no clock tick and catches up with one when it shows again. Best effort: a mount the supervisor
    /// does not know yet (its mount is still on the way) answers an error that changes nothing.
    public func setWidgetVisible(_ mount: AppMount, _ visible: Bool) {
        guard availability.isAvailable else { return }
        let args: AppJSON = ["mount_id": .string(mount.id), "visible": .bool(visible)]
        // After the mount on the same chain, so the supervisor knows the mount it is told about.
        enqueue { transport in _ = try? await transport.storeCall("apps.widgets.visible", args: args, origin: .script) }
    }

    /// Mounts `app`'s widget as tile `instance` of `place` at `size` (`apps-mount` with context
    /// `{place, size, instance, locale, timeZone}`; `preview` for the Add Widget gallery: sample
    /// data, writes nothing). Nil when the client does not know the app or it has no widget.
    public func mountWidget(_ app: String, place: String, size: AppWidgetSize, instance: String,
                            preview: Bool = false) -> AppMount? {
        guard let implementation = self.app(app)?.manifest.sceneImplementation(interface: Self.widgetInterface) else { return nil }
        // The person's locale (BCP 47, "en-US") and time zone: the widget's `ctx.locale` and `ctx.timeZone`.
        let context: [String: AppJSON] = [
            "place": .string(place), "size": .string(size.rawValue), "instance": .string(instance),
            "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
            "timeZone": .string(TimeZone.current.identifier),
        ]
        return mount(app, implementation: implementation, surface: Self.widgetSurface, preview: preview, context: context)
    }
}
