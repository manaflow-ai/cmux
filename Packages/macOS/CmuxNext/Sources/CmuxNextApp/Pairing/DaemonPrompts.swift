/// The local daemon's user-only prompts, started before the daemon connects: OSC 52 clipboard
/// reads (``TerminalClipboardReadService``) and browser pairings (``DaemonPairingApprovalService``).
@MainActor
struct DaemonPrompts {
    let clipboardReads: TerminalClipboardReadService
    let pairings: DaemonPairingApprovalService

    static func start(_ services: AppServices) -> DaemonPrompts {
        let prompts = DaemonPrompts(clipboardReads: TerminalClipboardReadService(services: services),
                                    pairings: DaemonPairingApprovalService(services: services))
        prompts.clipboardReads.start()
        prompts.pairings.start()
        return prompts
    }
}
