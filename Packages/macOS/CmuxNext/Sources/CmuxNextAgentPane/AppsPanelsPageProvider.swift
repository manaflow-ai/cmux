public import CmuxNextApps
public import CmuxNextPages
public import CmuxNextSettings
import Foundation
import CmuxNextCompat
import UniformTypeIdentifiers

/// The narrow page bridge for app scenes a React page draws: Session Info sections today, and the
/// app pane, sidebar sections and hover cards (``AppMountSurface``) as their pages move to React.
/// It shares the AppsClient's transport callback, so panel scene events cannot replace the App
/// Store's event handling.
///
/// Ops: `list`, `mount {surface, app, section?, context}` (answers `{mount_id, asset_base?}`),
/// `dispatch` and `reload {mount_id}` (both only from the person's own click or key), `layout
/// {mount_id, height}` and `unmount`. The `scene` stream carries each mount's ops batches and its
/// status, `{mount_id, status: loading|ready|failed|disconnected, reason?}`, as the host model has it,
/// and its kept view's refused save, `{mount_id, reload_failure: {reason}|null}`
/// (``AppSceneModel/reloadFailure``: the app's last saved script did not load, so a ready view still
/// draws the one before; null once a scene of a script that loaded replaces it), for every surface.
/// The page's `__appbundle/<mount_id>/<path>` resources are the mount's bundle images.
@MainActor
public final class AppsPanelsPageProvider: PageProvider, PageDynamicResourceSource {
    public static let namespace = "cmux.apps.panels."
    /// The dynamic prefix a page lists to show its mounts' bundle images (``resource(for:)``).
    public nonisolated static let bundlePrefix = "__appbundle"
    /// The largest bundle image served; a bigger file is a 404.
    nonisolated static let bundleImageLimit = 16 << 20

    private let client: AppsClient
    private var mounts: [String: AppMount] = [:]
    /// Scene ops of a mount that no subscriber heard yet (the page subscribes after `mount` answers).
    private var unheard: [String: [AppSceneOp]] = [:]
    private var sceneListeners: [UUID: (mountID: String?, callback: @MainActor (JSONValue) -> Void)] = [:]
    private var changedListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    /// The status each mount's page last heard (or would hear on subscribe), so a status goes out once per change.
    private var statuses: [String: AppSceneModel.Status] = [:]
    /// The refused save each mount's page last heard (or would hear on subscribe); absent for none.
    private var reloadFailures: [String: String] = [:]
    /// Each mount's drawn height, as its page last reported it (`layout`).
    private var heights: [String: Double] = [:]
    /// Each mount's status watch (``follow(_:)``).
    private var statusWatches: [String: Task<Void, Never>] = [:]
    /// Runs when a mount's reported height changes. No host reads it yet; the sidebar and hover
    /// card hosts size their page frames from it when they move to React.
    public var onLayout: (@MainActor (_ mountID: String, _ height: Double) -> Void)?
    /// The page serves ``bundlePrefix`` from this provider (its dynamic source answers through
    /// ``resource(for:)``): only then does a mount reply name an `asset_base`.
    public var servesBundleImages = false

    /// The route a page that may mount Session Info sections (the App Store page) adds.
    public static func route(_ client: AppsClient) -> PageRoute { PageRoute(prefix: namespace, provider: AppsPanelsPageProvider(client: client)) }

    public init(client: AppsClient) {
        self.client = client
        client.observeEvents(owner: self) { [weak self] event in self?.handle(event) }
    }

    /// The page closed or reloaded: its mounts end; the provider stays for the next document.
    public func pageDidClose() {
        for mount in mounts.values { client.unmount(mount) }
        mounts.removeAll()
        unheard.removeAll()
        statuses.removeAll()
        reloadFailures.removeAll()
        heights.removeAll()
        for watch in statusWatches.values { watch.cancel() }
        statusWatches.removeAll()
        sceneListeners.removeAll()
        changedListeners.removeAll()
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.namespace + "list":
            do {
                let panels = try await client.sessionInfoPanels()
                return .object(["panels": .array(panels.map(panelJSON))])
            } catch {
                throw PageError(code: "cmux.apps.panels.failed", message: String(describing: error), retryable: true)
            }
        case Self.namespace + "mount":
            return try mount(params)
        case Self.namespace + "dispatch":
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "This app panel action can only be used by a person")
            }
            return try dispatch(params)
        case Self.namespace + "reload":
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "Reloading an app view can only be done by a person")
            }
            return try reload(params)
        case Self.namespace + "layout":
            return try layout(params)
        case Self.namespace + "unmount":
            return try unmount(params)
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.namespace + "scene" || stream == Self.namespace + "changed" else {
            throw PageError.unknownOp(stream)
        }
        let id = UUID()
        if stream == Self.namespace + "scene" {
            let mountID = filter["mount_id"]?.stringValue
            sceneListeners[id] = (mountID, onEvent)
            if let mountID, let ops = unheard.removeValue(forKey: mountID) {
                onEvent(sceneJSON(mountID: mountID, ops: ops, reset: true))
            }
            // The page subscribes after `mount` answers: it hears where the mount is now.
            if let mountID, let mount = mounts[mountID] {
                statuses[mountID] = mount.model.status
                onEvent(statusJSON(mountID: mountID, status: mount.model.status))
                reloadFailures[mountID] = mount.model.reloadFailure
                if let reason = mount.model.reloadFailure { onEvent(reloadFailureJSON(mountID: mountID, reason: reason)) }
            }
            return PageSubscription { [weak self] in self?.sceneListeners.removeValue(forKey: id) }
        }
        changedListeners[id] = onEvent
        return PageSubscription { [weak self] in self?.changedListeners.removeValue(forKey: id) }
    }

    /// Mounts the app's implementation for `surface` (``AppMountSurface``), resolved as that surface's
    /// AppKit host resolves it; `section` names the section of a sidebar or Session Info mount.
    private func mount(_ params: JSONValue) throws -> JSONValue {
        guard let rawSurface = params["surface"]?.stringValue, let surface = AppMountSurface(rawValue: rawSurface),
              let app = params["app"]?.stringValue,
              let rawContext = params["context"], case .object = rawContext else {
            throw PageError.invalidParams("surface (pane, sidebarSection, hoverCard or sessionInfoSection), app and object context are required")
        }
        let section = params["section"]?.stringValue
        guard let record = client.app(app), let implementation = surface.implementation(of: record, id: section) else {
            throw PageError(code: "cmux.apps.panels.not_found", message: "No \(surface.rawValue) of \(app)\(section.map { "#" + $0 } ?? "") shows")
        }
        let context = appJSON(rawContext)
        let mount = client.mount(app, implementation: implementation, surface: surface.rawValue, context: context.objectValue ?? [:])
        mounts[mount.id] = mount
        statuses[mount.id] = mount.model.status
        reloadFailures[mount.id] = mount.model.reloadFailure
        follow(mount)
        var reply: [String: JSONValue] = ["mount_id": .string(mount.id)]
        if servesBundleImages, mount.bundleDirectory != nil { reply["asset_base"] = .string("/\(Self.bundlePrefix)/\(mount.id)/") }
        return .object(reply)
    }

    /// The failure row's Reload: the mount's app runs its saved script again and every view of it redraws.
    private func reload(_ params: JSONValue) throws -> JSONValue {
        guard let mountID = params["mount_id"]?.stringValue else { throw PageError.invalidParams("mount_id is required") }
        guard let mount = mounts[mountID] else { throw PageError(code: "cmux.apps.panels.not_found", message: "No such mount") }
        mount.reload()
        return .object([:])
    }

    /// The page's drawn height of a mount, kept for a native host that sizes the page's frame.
    private func layout(_ params: JSONValue) throws -> JSONValue {
        guard let mountID = params["mount_id"]?.stringValue,
              let height = params["height"]?.doubleValue, height.isFinite, height >= 0 else {
            throw PageError.invalidParams("mount_id and a height of 0 or more are required")
        }
        guard mounts[mountID] != nil else { throw PageError(code: "cmux.apps.panels.not_found", message: "No such mount") }
        guard heights[mountID] != height else { return .object([:]) }
        heights[mountID] = height
        onLayout?(mountID, height)
        return .object([:])
    }

    /// The height `mountID`'s page last reported, nil before its first `layout`.
    public func reportedHeight(mountID: String) -> Double? { heights[mountID] }

    private func dispatch(_ params: JSONValue) throws -> JSONValue {
        guard let mountID = params["mount_id"]?.stringValue,
              let node = params["node"]?.stringValue,
              let event = params["event"]?.stringValue else {
            throw PageError.invalidParams("mount_id, node and event are required")
        }
        guard let mount = mounts[mountID] else { throw PageError(code: "cmux.apps.panels.not_found", message: "No such mount") }
        let payload = appJSON(params["payload"] ?? .object([:]))
        mount.dispatch(node: node, event: event, payload: payload)
        return .object([:])
    }

    private func unmount(_ params: JSONValue) throws -> JSONValue {
        guard let mountID = params["mount_id"]?.stringValue else { throw PageError.invalidParams("mount_id is required") }
        guard let mount = mounts.removeValue(forKey: mountID) else { return .object([:]) }
        unheard.removeValue(forKey: mountID)
        statuses.removeValue(forKey: mountID)
        reloadFailures.removeValue(forKey: mountID)
        heights.removeValue(forKey: mountID)
        statusWatches.removeValue(forKey: mountID)?.cancel()
        client.unmount(mount)
        return .object([:])
    }

    private func handle(_ event: AppsTransportEvent) {
        switch event {
        case let .scene(mountID, ops, reset):
            guard mounts[mountID] != nil else { return }
            let listeners = sceneListeners.values.filter { $0.mountID == nil || $0.mountID == mountID }
            guard !listeners.isEmpty else {
                unheard[mountID] = reset ? ops : (unheard[mountID] ?? []) + ops
                return
            }
            let data = sceneJSON(mountID: mountID, ops: ops, reset: reset)
            for listener in listeners { listener.callback(data) }
        case .changed:
            for listener in changedListeners.values { listener(.null) }
        default:
            break
        }
        // The client handled the event first: a scene made its mount ready, a failure failed it,
        // a lost supervisor disconnected every mount, a refused save marked the app's drawn views and
        // a reset scene took that mark away.
        publishStatuses()
    }

    /// Sends each mount's status and refused save that changed since its page last heard them.
    private func publishStatuses() {
        for (mountID, mount) in mounts {
            publishStatus(mountID, mount.model.status)
            publishReloadFailure(mountID, mount.model.reloadFailure)
        }
    }

    /// Sends `mountID`'s refused save (`reason`), or its clearing (nil), once per change.
    private func publishReloadFailure(_ mountID: String, _ reason: String?) {
        guard mounts[mountID] != nil, reloadFailures[mountID] != reason else { return }
        reloadFailures[mountID] = reason
        let listeners = sceneListeners.values.filter { $0.mountID == nil || $0.mountID == mountID }
        // No subscriber yet: the page hears the refused save current when it subscribes.
        guard !listeners.isEmpty else { return }
        let data = reloadFailureJSON(mountID: mountID, reason: reason)
        for listener in listeners { listener.callback(data) }
    }

    private func publishStatus(_ mountID: String, _ status: AppSceneModel.Status) {
        guard mounts[mountID] != nil, statuses[mountID] != status else { return }
        statuses[mountID] = status
        let listeners = sceneListeners.values.filter { $0.mountID == nil || $0.mountID == mountID }
        // No subscriber yet: the page hears the status current when it subscribes.
        guard !listeners.isEmpty else { return }
        let data = statusJSON(mountID: mountID, status: status)
        for listener in listeners { listener.callback(data) }
    }

    /// Follows `mount`'s status and refused save for changes no supervisor event carries (a refused
    /// mount call, a reload that shows loading and drops the mark), for as long as the mount lives here.
    private func follow(_ mount: AppMount) {
        let model = mount.model
        let mountID = mount.id
        // task-owner: one watch per mount, cancelled when the page unmounts it or closes.
        statusWatches[mountID] = Task { [weak self] in
            for await state in ObservationStream({ MountState(status: model.status, reloadFailure: model.reloadFailure) }) {
                self?.publishStatus(mountID, state.status)
                self?.publishReloadFailure(mountID, state.reloadFailure)
            }
        }
    }

    // MARK: Bundle images

    /// `__appbundle/<mount_id>/<path>`: an image file inside that mount's app bundle, for this
    /// page's own mounts only. Each component is decoded once and must be a plain name (no `.`,
    /// `..`, separator or empty part), and the resolved file, symlinks followed, must stay inside the
    /// bundle; only image types are served, up to ``bundleImageLimit``. Anything else is a 404.
    public func resource(for request: PageResourceRequest) async -> PageResource? {
        guard request.prefix == Self.bundlePrefix, request.path.count >= 2,
              let mount = mounts[request.path[0]], let directory = mount.bundleDirectory,
              let file = Self.bundleFile(directory: directory, components: request.path.dropFirst()),
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let data = await Self.read(file) else { return nil }
        return PageResource(data: data, mimeType: type.preferredMIMEType)
    }

    /// The file `components` name inside `directory`, or nil when one is not a plain name or the
    /// resolved path leaves the directory.
    nonisolated static func bundleFile(directory: URL, components: ArraySlice<String>) -> URL? {
        var names: [String] = []
        for component in components {
            guard let name = component.removingPercentEncoding, !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = names.reduce(root) { $0.appending(path: $1, directoryHint: .notDirectory) }.standardizedFileURL.resolvingSymlinksInPath()
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(base) ? file : nil
    }

    @concurrent nonisolated private static func read(_ file: URL) async -> Data? {
        guard let size = try? file.blockingResourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              size.isRegularFile == true, (size.fileSize ?? 0) <= bundleImageLimit else { return nil }
        return try? Data(blockingContentsOf: file, options: .mappedIfSafe)
    }
}

// The page speaks JSONValue, the apps client AppJSON: the same JSON, converted at this edge.

private func panelJSON(_ panel: AppSessionInfoPanel) -> JSONValue {
    var value: [String: JSONValue] = ["app": .string(panel.app), "section": .string(panel.section), "title": .string(panel.title)]
    if let symbol = panel.symbol { value["symbol"] = .string(symbol) }
    if let maxRows = panel.maxRows { value["maxRows"] = .number(Double(maxRows)) }
    return .object(value)
}

private func sceneJSON(mountID: String, ops: [AppSceneOp], reset: Bool) -> JSONValue {
    var value: [String: JSONValue] = ["mount_id": .string(mountID), "ops": .array(ops.map { pageJSON($0.json) })]
    if reset { value["reset"] = .bool(true) }
    return .object(value)
}

/// `{mount_id, status, reason?}`: the host model's status, the failure's raw reason or the disconnected line.
private func statusJSON(mountID: String, status: AppSceneModel.Status) -> JSONValue {
    var value: [String: JSONValue] = ["mount_id": .string(mountID)]
    switch status {
    case .loading: value["status"] = .string("loading")
    case .ready: value["status"] = .string("ready")
    case let .failed(reason):
        value["status"] = .string("failed")
        value["reason"] = .string(reason)
    case let .disconnected(reason):
        value["status"] = .string("disconnected")
        value["reason"] = .string(reason)
    }
    return .object(value)
}

/// `{mount_id, reload_failure: {reason}|null}`: the kept view's refused save, or none.
private func reloadFailureJSON(mountID: String, reason: String?) -> JSONValue {
    .object(["mount_id": .string(mountID), "reload_failure": reason.map { .object(["reason": .string($0)]) } ?? .null])
}

/// What ``AppsPanelsPageProvider`` follows of a mount's model.
private struct MountState: Equatable, Sendable {
    let status: AppSceneModel.Status
    let reloadFailure: String?
}

private func pageJSON(_ value: AppJSON) -> JSONValue {
    switch value {
    case .null: .null
    case let .bool(value): .bool(value)
    case let .number(value): .number(value)
    case let .string(value): .string(value)
    case let .array(values): .array(values.map(pageJSON))
    case let .object(values): .object(values.mapValues(pageJSON))
    }
}

private func appJSON(_ value: JSONValue) -> AppJSON {
    switch value {
    case .null: .null
    case let .bool(value): .bool(value)
    case let .number(value): .number(value)
    case let .string(value): .string(value)
    case let .array(values): .array(values.map(appJSON))
    case let .object(values): .object(values.mapValues(appJSON))
    }
}
