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

    /// Tells the supervisor whether a widget tile shows (`apps.widgets.visible`): a hidden tile gets
    /// no clock tick and catches up with one when it shows again. Best effort: a mount the supervisor
    /// does not know yet (its mount is still on the way) answers an error that changes nothing.
    public func setWidgetVisible(_ mount: AppMount, _ visible: Bool) {
        guard availability.isAvailable else { return }
        let args: AppJSON = ["mount_id": .string(mount.id), "visible": .bool(visible)]
        // After the mount on the same chain, so the supervisor knows the mount it is told about.
        enqueue { transport in _ = try? await transport.storeCall("apps.widgets.visible", args: args, origin: .script) }
    }
}
