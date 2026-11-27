import CmuxNextDaemon
/// The local daemon's user-only prompts, started before the daemon connects: OSC 52 clipboard
/// reads, browser pairings, and keys it gives back (``TerminalInputUnclaimed``) to the focused terminal of their own window.
@MainActor
struct DaemonPrompts {
    let clipboardReads: TerminalClipboardReadService
    let pairings: DaemonPairingApprovalService

    static func start(_ services: AppServices, afterFrame: @MainActor (@escaping @MainActor () -> Void) -> Void) -> DaemonPrompts {
        let prompts = DaemonPrompts(clipboardReads: TerminalClipboardReadService(services: services),
                                    pairings: DaemonPairingApprovalService(services: services))
        afterFrame { prompts.clipboardReads.start() } // its feed walks every workspace: after the first frame (launch piece 7)
        prompts.pairings.start()
        _ = services.daemon.store.sideEvents.subscribe { [weak services] event in
            guard let unclaimed = TerminalInputUnclaimed(event), let bytes = unclaimed.bytes else { return }
            services?.keyRouter.creationInputCoordinator.giveBack(bytes, terminal: unclaimed.terminalId)
        }
        return prompts
    }
}
