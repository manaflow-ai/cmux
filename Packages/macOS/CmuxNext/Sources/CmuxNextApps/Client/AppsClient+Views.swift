public import CmuxNextSettings

/// The open views of apps, for `apps.views` (`cmux app call apps.views`).
extension AppsClient {
    /// Every mount this client holds (sidebar sections, panes, hover cards, previews), in mount order.
    public var openMounts: [AppMount] {
        mounts.values.sorted { ($0.id.count, $0.id) < ($1.id.count, $1.id) }
    }

    /// Each open extension view with what it shows now: its status, the reason a saved script was
    /// refused, the title its current manifest gives it and the words of its scene. Read from this
    /// client's mirror of the supervisor's scene stream, so it reads what the window draws, in every
    /// build. `app` keeps one app's views.
    public func viewsReport(app only: String?) -> CmuxNextSettings.JSONValue {
        let views: [CmuxNextSettings.JSONValue] = openMounts.compactMap { mount in
            if let only, mount.appID != only { return nil }
            var object: [String: CmuxNextSettings.JSONValue] = [
                "mount_id": .string(mount.id), "app": .string(mount.appID),
                "interface": .string(mount.implementation.interface), "implementation": .string(mount.implementation.id),
                "surface": .string(mount.surface), "preview": .bool(mount.isPreview),
                "revision": .number(Double(mount.model.revision)),
                "texts": .array(mount.model.scene.texts().map { .string($0) }),
            ]
            let manifest = app(mount.appID)?.manifest
            if let title = manifest?.sceneImplementation(interface: mount.implementation.interface)?.title?.resolved() {
                object["title"] = .string(title)
            }
            switch mount.model.status {
            case .loading: object["status"] = .string("loading")
            case .ready: object["status"] = .string("ready")
            case .failed(let reason):
                object["status"] = .string("failed")
                object["reason"] = .string(reason)
            case .disconnected(let reason):
                object["status"] = .string("disconnected")
                object["reason"] = .string(reason)
            }
            if let failure = mount.model.reloadFailure { object["reload_failure"] = .string(failure) }
            return .object(object)
        }
        return .object(["views": .array(views)])
    }
}
