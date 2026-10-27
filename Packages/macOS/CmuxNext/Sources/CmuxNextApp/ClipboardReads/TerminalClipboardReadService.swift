import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextWakeups

/// The Mac side of the OSC 52 clipboard-read broker (decision
/// CLIPBOARD-READ-BROKER, layer 4) on the local daemon connection only:
/// remote and Cloud connections never subscribe in this landing (S3), so
/// their reads are refused by their daemons. Keeps the subscription equal to
/// the local store's terminals by observing the store (one apply on the run
/// loop pass after a change, no polling) and answers each read from the
/// user's Ghostty `clipboard-read` setting or a cmux dialog in that terminal's tab. A local
/// PTY may contain SSH or another nested transport, so its program origin is
/// deliberately unproven: `allow` degrades to `ask` and the dialog does not
/// claim the requester is this Mac.
@MainActor
final class TerminalClipboardReadService {
    /// The daemon is local, but the program behind its PTY may not be.
    static let requestHost = ClipboardReadHost(kind: .unknown)

    private weak var services: AppServices?
    private var broker: TerminalClipboardBroker?
    private var sideEvents: UInt64?
    /// The local store's connection and terminal set, handed to the broker on each change.
    private var storeWatch: FrameObservation<Watched>?
    private var stopped = false
    /// Hand-offs of the connection and terminal set to the broker (tests count the deliveries).
    private(set) var handOffs = 0

    /// What the broker's subscription follows.
    private struct Watched {
        var connected: Bool
        var terminals: [String]
    }

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        guard broker == nil, let daemon = services?.daemon else { return }
        let capability = DaemonCapability.terminalClipboardRead.rawValue
        broker = TerminalClipboardBroker(host: Self.requestHost, environment: .init(
            setting: { ClipboardReadSetting(ghosttyValue: GhosttyRuntime.shared.clipboardReadValue) },
            // Primary and selection have no Mac pasteboard of their own; the
            // general one is what the user copied.
            pasteboardText: { _ in NSPasteboard.general.string(forType: .string) },
            ask: Self.dialogAsk(center: .shared) { [weak self] prompt in self?.placement(for: prompt) },
            subscribe: { [weak daemon] terminals in
                guard let daemon, let connection = daemon.connection, daemon.supports(capability) else {
                    throw DaemonError.notConnected
                }
                _ = try await connection.request(TerminalClipboardSubscribeRequest(terminalIDs: terminals))
            },
            reply: { [weak daemon] requestID, text in
                guard let connection = daemon?.connection else { throw DaemonError.notConnected }
                _ = try await connection.request(TerminalClipboardReplyRequest(requestID: requestID, text: text))
            }))
        // The store watch's same-turn reader: a disconnect or a terminal-set change earlier in this turn reaches the
        // broker before the event does.
        sideEvents = daemon.store.sideEvents.subscribe { [weak self] event in
            self?.storeWatch?.flushIfDirty()
            self?.broker?.handle(event)
        }
        observe()
    }

    func stop() {
        stopped = true
        storeWatch?.cancel()
        storeWatch = nil
        broker?.stop()
        if let sideEvents { services?.daemon.store.sideEvents.unsubscribe(sideEvents) }
        sideEvents = nil
    }

    /// Follows the connection and the terminal set and hands each change to the broker.
    private func observe() {
        guard !stopped, broker != nil, let services else { return }
        let capability = DaemonCapability.terminalClipboardRead.rawValue
        let store = services.daemon.store
        let watch = FrameObservation(
            owner: "clipboard-reads.terminals",
            delivery: .sameTurn("the side-event handler flushes it, so a read in the turn of a disconnect or a terminal-set change sees them"),
            on: services.mainWork
        ) { [weak store] in
            guard let store else { return Watched(connected: false, terminals: []) }
            let connected = Self.isConnected(store.connectionState) && store.supports(capability)
            return Watched(connected: connected, terminals: Self.terminalIDs(store))
        } onChange: { [weak self] watched in
            self?.hand(watched)
        }
        storeWatch = watch
        hand(watch.value)
    }

    private func hand(_ watched: Watched) {
        guard !stopped, let broker, let store = services?.daemon.store else { return }
        handOffs += 1
        // The epoch changes on every reconnect, which resubscribes.
        broker.setConnection(watched.connected ? store.connectionEpoch : nil)
        broker.setTerminals(watched.terminals)
    }

    private static func isConnected(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    /// Public ids of the terminals this Mac shows from the local daemon.
    /// Remote-terminal tabs live on another session and are not included.
    private static func terminalIDs(_ store: DaemonStore) -> [String] {
        var ids: [String] = []
        for workspace in store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.kind == .pty {
                        if let id = tab.terminalResourceID?.rawValue { ids.append(id) }
                    }
                }
            }
        }
        return ids
    }

    private func tab(terminal id: String) -> TabModel? {
        for workspace in services?.daemon.store.workspaces ?? [] {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { $0.terminalResourceID?.rawValue == id }) { return tab }
                }
            }
        }
        return nil
    }

    // MARK: Asking

    /// Where a prompt's dialog goes: the terminal's tab title (nil when it
    /// has none) and the scope that blocks only that tab when its view is on
    /// screen, else the active window.
    struct Placement {
        var terminalTitle: String?
        var scope: CmuxDialogScope
    }

    /// The broker's `ask`: one dialog in `center` naming the terminal and
    /// the host. Allow grants; Deny, Escape and every dismissal refuse. The
    /// closer it returns (a cancelled read) dismisses the dialog, which
    /// answers Deny to a broker that no longer waits on it. No placement (the
    /// service is gone) shows nothing.
    static func dialogAsk(center: CmuxDialogCenter, place: @escaping @MainActor (ClipboardReadPrompt) -> Placement?)
        -> @MainActor (ClipboardReadPrompt, @escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void {
        { prompt, answer in
            guard let placement = place(prompt) else { return {} }
            let title = placement.terminalTitle.flatMap { $0.isEmpty ? nil : $0 } ?? ClipboardReadStrings.untitledTerminal
            let host: String? = switch prompt.host.kind {
            case .local: ClipboardReadStrings.thisMac
            case .remote, .cloud: prompt.host.name ?? ClipboardReadStrings.otherMachine
            case .unknown: nil
            }
            let spec = ClipboardReadStrings.spec(terminal: title, host: host)
            let id = center.present(spec, in: placement.scope) { result in
                answer(result.button == ClipboardReadStrings.allowID)
            }
            return { _ = center.dismiss(id) }
        }
    }

    private func placement(for prompt: ClipboardReadPrompt) -> Placement {
        let tab = tab(terminal: prompt.terminalID)
        return Placement(terminalTitle: tab?.displayTitle, scope: scope(for: tab))
    }

    private func scope(for tab: TabModel?) -> CmuxDialogScope {
        let cache = services?.cache
        guard let tab, let cache, let view = cache.existingTerminal(tab.id)?.session.view else {
            return Self.scope(tabView: nil, tabNode: nil, activeWindow: services?.windows.active?.window)
        }
        return Self.scope(tabView: view, tabNode: cache.node(for: tab.id), activeWindow: services?.windows.active?.window)
    }

    /// The dialog's scope: the tab's view while its node is shown (p06 recipe R-vis, no walk up the views), else the
    /// active window, else the app. An occluded window (covered, or cmux behind another app) still shows the tab: only a
    /// hidden node (an unselected tab, a parked workspace, a miniaturized window) moves the prompt off it.
    static func scope(tabView view: NSView?, tabNode node: VisibilityNode?, activeWindow: NSWindow?) -> CmuxDialogScope {
        if let view, view.window != nil, let node, node.effective > .hidden { return .tab(view) }
        if let activeWindow { return .window(activeWindow) }
        return .app
    }
}
