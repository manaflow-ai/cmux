import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTerminal

/// The Mac side of the OSC 52 clipboard-read broker (decision
/// CLIPBOARD-READ-BROKER, layer 4) on the local daemon connection only:
/// remote and Cloud connections never subscribe in this landing (S3), so
/// their reads are refused by their daemons. Keeps the subscription equal to
/// the local store's terminals by observing the store (the connection, and each
/// workspace's terminals on their own: no polling, and a tab that comes or goes
/// re-reads its workspace only) and answers each read from the user's Ghostty
/// `clipboard-read` setting or a cmux dialog in that terminal's tab. A local
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
    /// Each workspace's terminals, one observation per workspace: a new tab used to cancel and re-arm one tracking
    /// of every tab of the session in the key's turn (CMD-T BUDGET 2026-11-10).
    private var terminals: ObservedItemsFeed<WorkspaceModel, [String]>?
    /// Follows the connection and the feed's items (three cells); ends with the service.
    private var observation: Task<Void, Never>?

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
        sideEvents = daemon.store.sideEvents.subscribe { [weak self] event in self?.broker?.handle(event) }
        let store = daemon.store
        let terminals = ObservedItemsFeed<WorkspaceModel, [String]>(
            list: { [weak store] in store?.workspaces },
            // By object: a workspace the store replaced is a new model.
            id: { "\(ObjectIdentifier($0))" }, item: { $0.terminalResourceIDs })
        self.terminals = terminals
        terminals.start()
        observation = Task { [weak self] in
            for await (connected, ids) in ObservationStream({
                (TerminalClipboardReadService.isConnected(store.connectionState) && store.supports(capability), terminals.observedItems)
            }) {
                guard let broker = self?.broker else { return }
                // The epoch changes on every reconnect, which resubscribes.
                broker.setConnection(connected ? store.connectionEpoch : nil)
                if let ids { broker.setTerminals(ids.joined()) } // nil: the workspaces are not read yet
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        terminals?.stop()
        terminals = nil
        broker?.stop()
        if let sideEvents { services?.daemon.store.sideEvents.unsubscribe(sideEvents) }
        sideEvents = nil
    }

    private static func isConnected(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
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
        let tab = services?.daemon.store.tab(terminalResource: ResourceID(rawValue: prompt.terminalID))
        return Placement(terminalTitle: tab?.displayTitle, scope: scope(for: tab))
    }

    private func scope(for tab: TabModel?) -> CmuxDialogScope {
        if let tab, let view = services?.cache.existingTerminal(tab.id)?.session.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor {
            return .tab(view)
        }
        if let window = services?.windows.active?.window { return .window(window) }
        return .app
    }
}
