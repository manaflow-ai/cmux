import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTerminal
import Observation

/// The Mac side of the OSC 52 clipboard-read broker (decision
/// CLIPBOARD-READ-BROKER, layer 4) on the local daemon connection only:
/// remote and Cloud connections never subscribe in this landing (S3), so
/// their reads are refused by their daemons. Keeps the subscription equal to
/// the local store's terminals by observing the store (re-armed after each
/// change, no polling) and answers each read from the user's Ghostty
/// `clipboard-read` setting or a cmux dialog in that terminal's tab.
@MainActor
final class TerminalClipboardReadService {
    private weak var services: AppServices?
    private var broker: TerminalClipboardBroker?
    private var sideEvents: UInt64?
    private var stopped = false

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        guard broker == nil, let daemon = services?.daemon else { return }
        let capability = DaemonCapabilities.shared.terminalClipboardRead
        broker = TerminalClipboardBroker(host: ClipboardReadHost(kind: .local), environment: .init(
            setting: { ClipboardReadSetting(ghosttyValue: GhosttyRuntime.shared.clipboardReadValue) },
            // Primary and selection have no Mac pasteboard of their own; the
            // general one is what the user copied.
            pasteboardText: { _ in NSPasteboard.general.string(forType: .string) },
            ask: { [weak self] prompt, answer in
                self?.present(prompt, answer: answer) ?? {}
            },
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
        observe()
    }

    func stop() {
        stopped = true
        broker?.stop()
        if let sideEvents { services?.daemon.store.sideEvents.unsubscribe(sideEvents) }
        sideEvents = nil
    }

    /// Hands the broker the connection and the terminal set, then re-arms.
    private func observe() {
        guard !stopped, let broker, let store = services?.daemon.store else { return }
        let capability = DaemonCapabilities.shared.terminalClipboardRead
        let (connected, terminals) = withObservationTracking {
            (Self.isConnected(store.connectionState) && store.supports(capability), Self.terminalIDs(store))
        } onChange: { [weak self] in
            // task-owner: one hop per observed change, re-arms itself; ends with the service
            Task { @MainActor [weak self] in self?.observe() }
        }
        // The epoch changes on every reconnect, which resubscribes.
        broker.setConnection(connected ? store.connectionEpoch : nil)
        broker.setTerminals(terminals)
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

    /// One dialog naming the terminal (its tab title) and the host. It
    /// blocks only that tab when its view is on screen, else the active
    /// window. Returns the closer for a cancelled read.
    private func present(_ prompt: ClipboardReadPrompt, answer: @escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void {
        let tab = tab(terminal: prompt.terminalID)
        let title = tab.map(\.displayTitle).flatMap { $0.isEmpty ? nil : $0 } ?? ClipboardReadStrings.untitledTerminal
        let host = prompt.host.kind == .local ? ClipboardReadStrings.thisMac : (prompt.host.name ?? ClipboardReadStrings.otherMachine)
        let spec = ClipboardReadStrings.spec(terminal: title, host: host)
        let center = CmuxDialogCenter.shared
        let id = center.present(spec, in: scope(for: tab)) { result in answer(result.button == ClipboardReadStrings.allowID) }
        return { _ = center.dismiss(id) }
    }

    private func scope(for tab: TabModel?) -> CmuxDialogScope {
        if let tab, let view = services?.cache.existingTerminal(tab.id)?.session.view, view.window != nil {
            return .tab(view)
        }
        if let window = services?.windows.active?.window { return .window(window) }
        return .app
    }
}
