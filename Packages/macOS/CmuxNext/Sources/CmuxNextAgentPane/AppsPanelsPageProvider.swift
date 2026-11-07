public import CmuxNextApps
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The narrow page bridge for app-owned Session Info sections. It shares the
/// AppsClient's transport callback, so panel scene events cannot replace the
/// App Store's event handling.
@MainActor
public final class AppsPanelsPageProvider: PageProvider {
    public static let namespace = "cmux.apps.panels."

    private let client: AppsClient
    private var mounts: [String: AppMount] = [:]
    /// Scene ops of a mount that no subscriber heard yet (the page subscribes after `mount` answers).
    private var unheard: [String: [AppSceneOp]] = [:]
    private var sceneListeners: [UUID: (mountID: String?, callback: @MainActor (JSONValue) -> Void)] = [:]
    private var changedListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

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
            return PageSubscription { [weak self] in self?.sceneListeners.removeValue(forKey: id) }
        }
        changedListeners[id] = onEvent
        return PageSubscription { [weak self] in self?.changedListeners.removeValue(forKey: id) }
    }

    private func mount(_ params: JSONValue) throws -> JSONValue {
        guard let app = params["app"]?.stringValue,
              let section = params["section"]?.stringValue,
              let rawContext = params["context"], case .object = rawContext else {
            throw PageError.invalidParams("app, section and object context are required")
        }
        guard let record = client.app(app), record.isVisible,
              let implementation = record.manifest.sessionInfoSections.first(where: { $0.id == section }) else {
            throw PageError(code: "cmux.apps.panels.not_found", message: "No visible Session Info section \(app)#\(section)")
        }
        let context = appJSON(rawContext)
        let mount = client.mount(app, implementation: implementation, surface: "sessionInfoSection", context: context.objectValue ?? [:])
        mounts[mount.id] = mount
        return .object(["mount_id": .string(mount.id)])
    }

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
