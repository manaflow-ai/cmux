import CmuxHomeCore
import CmuxHomeRender
import CmuxNextApps
import CmuxNextCompat
import Foundation

/// Runs the Home chat's widgets with the app platform (plans/cmux-next/chat-widgets-DESIGN.md
/// section 4): a widget part names an app; when that app is installed, presented and implements
/// `cmux.chat.widget/1` with a script, the widget mounts it with `ctx.props` (the part's props)
/// and `ctx.widget.key` (`<message>#<part>`, its storage key), and its scene maps to a snapshot
/// the transcript draws natively. Scripts run in the daemon's sandboxed app host with the app's
/// granted scopes; this only mounts, maps and forwards clicks.
@MainActor
final class ChatWidgetHost: HomeWidgetHosting {
    static let interface = "cmux.chat.widget/1"
    static let surface = "chatWidget"

    private struct Entry {
        var mount: AppMount
        var watch: Task<Void, Never>
        var app: String
        var props: String
        var snapshot: HomeWidgetSnapshot?
    }

    private let client: AppsClient
    private let isPresented: (String) -> Bool
    private let mapping = ChatWidgetSceneMapping()
    private var entries: [String: Entry] = [:]
    private var owners: [ObjectIdentifier: Set<String>] = [:]
    private var listeners: [UUID: AsyncStream<String>.Continuation] = [:]

    init(client: AppsClient, isPresented: @escaping (String) -> Bool) {
        self.client = client
        self.isPresented = isPresented
    }

    func snapshot(for key: String, widget: ChatWidget) -> HomeWidgetSnapshot? {
        if let entry = entries[key] {
            if entry.app == widget.app, entry.props == widget.propsJSON { return entry.snapshot }
            // The sender edited the part (new props or app): mount again.
            release(key)
        }
        guard let app = client.app(widget.app), isPresented(app.id),
              let implementation = app.manifest.implementations.first(where: { $0.interface == widget.widget && $0.hasScene })
        else { return nil }
        let props = (try? AppJSON.parse(widget.propsJSON)).flatMap { $0.objectValue.map(AppJSON.object) } ?? .object([:])
        let mount = client.mount(app.id, implementation: implementation, surface: Self.surface,
                                 context: ["props": props, "widget": .object(["key": .string(key)])])
        let model = mount.model
        // task-owner: one watch per mounted widget, cancelled when it is released.
        let watch = Task { @MainActor [weak self] in
            for await _ in ObservationStream({ (model.status, model.scene) }) {
                self?.sceneChanged(key, model: model)
            }
        }
        entries[key] = Entry(mount: mount, watch: watch, app: widget.app, props: widget.propsJSON,
                             snapshot: Self.ready(model) ? mapping.snapshot(model.scene) : nil)
        return entries[key]?.snapshot
    }

    func tap(key: String, node: String) {
        entries[key]?.mount.dispatch(node: node, event: "tap", payload: .object([:]))
    }

    func keep(_ keys: Set<String>, owner: ObjectIdentifier) {
        owners[owner] = keys.isEmpty ? nil : keys
        let kept = owners.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for key in Array(entries.keys) where !kept.contains(key) { release(key) }
    }

    func changes() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(64))
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return stream
    }

    /// A failed or disconnected mount draws the fallback (nil), never a stale card.
    private static func ready(_ model: AppSceneModel) -> Bool { model.status == .ready }

    private func sceneChanged(_ key: String, model: AppSceneModel) {
        guard var entry = entries[key] else { return }
        let next = Self.ready(model) ? mapping.snapshot(model.scene) : nil
        guard next != entry.snapshot else { return }
        entry.snapshot = next
        entries[key] = entry
        for listener in listeners.values { listener.yield(key) }
    }

    private func release(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.watch.cancel()
        client.unmount(entry.mount)
    }
}
