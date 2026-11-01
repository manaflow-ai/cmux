import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// Session Info's Remote Control switch (Environment section): whether cmux on the person's iPhone
/// may open this Mac's agent chats, as Claude desktop's Remote Control lets a phone continue a
/// local session. It is the iPhone host's own switch, `mobile.allowIPhoneConnections` (the Mobile
/// Pairing page and Settings > Mobile show the same one), so it covers every chat on this Mac, not
/// only the one the panel shows. The iPhone host owns the one instance and sets ``state`` and ``set``;
/// the App gives it to every chat page's model (``AgentPaneModel/remoteControl``). Each page gets the
/// state at load and handshake (`remoteControl`), and again on every change. Nil state (no account
/// signed in, or a build with no iPhone host) sends null, and the page draws no row. Not an
/// AgentPaneView extension: that type is at its size limit. It lives as long as the app: no deinit
/// cancels ``follow()``'s task, which holds it weakly.
public final class AgentPaneRemoteControl {
    public init() {}

    /// The switch as the page shows it.
    public nonisolated struct State: Equatable, Sendable {
        public var on: Bool
        public init(on: Bool) { self.on = on }
    }

    /// The switch now, read through Observation (the App reads its settings and the iPhone host);
    /// nil while this Mac cannot serve phones.
    public var state: @MainActor () -> State? = { nil } {
        didSet { observation?.cancel(); observation = nil; follow(); for view in views.allObjects { send(to: view) } }
    }
    /// Writes the switch as the person's own change (the App's settings write, `by: .user`).
    public var set: (@MainActor (Bool) async throws -> Void)?

    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    private var observation: Task<Void, Never>?

    /// The switch, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        follow()
        return Self.event(state())
    }

    static func event(_ state: State?) -> AgentPageEvent {
        AgentPageEvent(kind: "remoteControl", value: state.map { ["on": .bool($0.on)] } ?? .null)
    }

    /// Pushes the switch, read now, to `view`'s page (the legacy host's handshake); `view` then also
    /// gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        follow()
        send(to: view)
    }

    /// The script that gives a legacy-host page the switch (`applyRemoteControl`, App.tsx).
    static func script(_ state: State?) -> String {
        "window.cmuxAcpmuxBridge?.applyRemoteControl?.(\(event(state).value.compactText));"
    }

    private func send(to view: AgentPaneView) {
        let state = state()
        view.deliver([Self.event(state)], scripts: [Self.script(state)])
    }

    private func follow() {
        guard observation == nil else { return }
        // task-owner: app-lifetime (one shared instance); event-driven (Observation on the setting
        // and the iPhone host's account). Cancelled and restarted when the iPhone host sets ``state``.
        observation = Task { [weak self] in
            var last: State??
            for await now in ObservationStream({ [weak self] in self?.state() }) {
                guard let self else { return }
                if last == .some(now) { continue }
                // The first value is the one ``event(for:)`` already gave each page.
                if last != nil { for view in views.allObjects { send(to: view) } }
                last = .some(now)
            }
        }
    }

    /// `pane.setRemoteControl {on}`: only the person's own click on the switch, for a chat on this
    /// Mac while the switch is shown.
    @MainActor
    static func reply(on: Bool, in model: AgentPaneModel, userGesture: Bool) async -> [String: Any] {
        guard !model.remoteChat, let control = model.remoteControl, control.state() != nil, let set = control.set else {
            return AgentPaneModel.unsupported("pane.setRemoteControl")
        }
        // Which phones reach this Mac is the person's call: a page script cannot make a gesture.
        guard userGesture || model.transport.gestures.consume() else {
            return AgentPaneModel.transportFailure(.gestureRequired)
        }
        do {
            try await set(on)
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "settings_write_failed", message: error.localizedDescription)
        }
    }
}
