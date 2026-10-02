public import Foundation

/// One mounted implementation (a sidebar section, a status item, a store
/// preview): its scene model, fed by the supervisor's `apps-scene` stream,
/// and where its user events go (`apps-dispatch` with origin `user`).
@MainActor
public final class AppMount: AppSceneInteraction, Identifiable {
    public let id: String
    public let appID: String
    public let implementation: AppImplementation
    /// A preview of an app that is not installed (no grants, sample data).
    public let isPreview: Bool
    public let surface: String
    public let model = AppSceneModel()
    /// Bundle files the scene's images come from, when this Mac has them.
    public let bundleDirectory: URL?
    weak var client: AppsClient?

    init(id: String, appID: String, implementation: AppImplementation, isPreview: Bool, surface: String, bundleDirectory: URL?,
         client: AppsClient) {
        self.id = id
        self.appID = appID
        self.implementation = implementation
        self.isPreview = isPreview
        self.surface = surface
        self.bundleDirectory = bundleDirectory
        self.client = client
        model.interaction = self
    }

    public func dispatch(node: String, event: String, payload: AppJSON) {
        client?.dispatch(self, node: node, event: event, payload: payload)
    }

    /// A fresh `AppSceneHostingView` for AppKit hosts (the sidebar).
    public func makeView() -> AppSceneHostingView { AppSceneHostingView(model: model, bundleDirectory: bundleDirectory) }

    var context: AppJSON {
        var context: [String: AppJSON] = ["contribution": .string("\(appID)#\(implementation.id)"), "surface": .string(surface)]
        if isPreview { context["preview"] = true }
        return .object(context)
    }
}

/// Mounts: a mount lives until `unmount`; it re-mounts with the same id
/// after every reconnect and shows the disconnected reason meanwhile.
extension AppsClient {
    /// Mounts `implementation` of `app`. A preview mounts an app that is
    /// not installed (`context.preview = true`: no grants, sample data).
    public func mount(_ app: String, implementation: AppImplementation, surface: String, preview: Bool = false) -> AppMount {
        let mount = AppMount(id: "mnt-\(keyPrefix)-\(nextMount)", appID: app,
                             implementation: implementation, isPreview: preview, surface: surface,
                             bundleDirectory: AppBundleLocator.directory(for: app), client: self)
        nextMount += 1
        mounts[mount.id] = mount
        send(mount)
        return mount
    }

    public func unmount(_ mount: AppMount) {
        guard mounts.removeValue(forKey: mount.id) != nil, availability.isAvailable else { return }
        // task-owner: one unmount; the supervisor also drops mounts of a closed connection
        Task { [transport] in try? await transport.unmount(mountID: mount.id) }
    }

    var liveMounts: [AppMount] { Array(mounts.values) }

    func remountAll() {
        for mount in mounts.values { send(mount) }
    }

    private func send(_ mount: AppMount) {
        guard availability.isAvailable else {
            mount.model.status = .disconnected(AppsStrings.unavailable(unavailableReason ?? .notConnected))
            return
        }
        mount.model.reset()
        // task-owner: one apps-mount; the scene stream reports the rest
        Task { [weak self, transport] in
            do throws(AppsTransportError) {
                try await transport.mount(app: mount.appID, interface: mount.implementation.interface, mountID: mount.id, context: mount.context)
            } catch {
                guard self?.mounts[mount.id] != nil else { return }
                mount.model.status = .failed(error.message)
            }
        }
    }

    func dispatch(_ mount: AppMount, node: String, event: String, payload: AppJSON) {
        guard availability.isAvailable, mounts[mount.id] != nil else { return }
        let previous = dispatchTail
        // task-owner: one user event, chained after the previous one so events arrive in order
        dispatchTail = Task { [transport] in
            await previous?.value
            try? await transport.dispatch(mountID: mount.id, node: node, event: event, payload: payload)
        }
    }
}
