import CmuxNextDaemon
/// The local daemon's user-only prompts, started before the daemon connects: OSC 52 clipboard
/// reads, browser pairings, and keys it gives back (``TerminalInputUnclaimed``) to the focused terminal.
@MainActor
struct DaemonPrompts {
    let clipboardReads: TerminalClipboardReadService
    let pairings: DaemonPairingApprovalService

    static func start(_ services: AppServices) -> DaemonPrompts {
        let prompts = DaemonPrompts(clipboardReads: TerminalClipboardReadService(services: services),
                                    pairings: DaemonPairingApprovalService(services: services))
        prompts.clipboardReads.start()
        prompts.pairings.start()
        _ = services.daemon.store.sideEvents.subscribe { [weak services] event in
            if let bytes = TerminalInputUnclaimed(event)?.bytes { services?.cache.terminals.values.first { $0.session.model.isFocused }?.session.sendBytes(bytes) }
        }
        return prompts
    }
}
