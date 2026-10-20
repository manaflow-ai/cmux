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
        _ = services.daemon.store.sideEvents.subscribe { [weak services] in TerminalInputUnclaimed($0)?.bytes.map { services?.keyRouter.creationInputCoordinator.giveBack($0) } }
        return prompts
    }
}
