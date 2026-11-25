public import CmuxNextDaemon
public import Foundation

/// A Cloud machine session's own redial after its link was refused as not up yet (`CloudLinkError.notUp`, the
/// carrier's `parked_timeout`: the relay held the dial its whole 180 s deadline and the machine's host never paired).
/// Nothing else dials a machine again while its record stays running, so cloud-chats-11 showed "The machine's
/// connection isn't ready yet (parked_timeout). Click Connect to try again." with its carrier up for 40 minutes
/// (cmux#57192). The waits are Rust's (`redial_after_not_up`, cmux-cloud-machine `rules.rs`): growing, about twenty
/// minutes in all, then the machine shows its Connect as before. Any other refusal waits for a click.
@MainActor
public final class CloudNotUpRedial {
    /// Refusals as not up yet in a row; a daemon that answers or a person's connect starts again from 0.
    public private(set) var refusals = 0
    /// The wait after `attempt` refusals in a row on `machine`; nil: no redial. Tests shorten it.
    public var delay: @MainActor (_ machine: CloudMachine, _ attempt: Int) -> Duration? = { $0.redialAfterNotUp(attempt: $1) }
    private var pending: Task<Void, Never>?

    public init() {}

    /// A connect starts: the pending redial is spent, and a person's connect counts from the first wait again.
    public func connecting(byPerson: Bool) {
        pending?.cancel()
        pending = nil
        if byPerson { refusals = 0 }
    }

    /// The link's daemon answered through `endpoint`: the refusals in a row end.
    public func answering<T>(_ endpoint: () async throws -> T) async throws -> T {
        let answer = try await endpoint()
        refusals = 0
        return answer
    }

    /// The link ended with `error` on `machine`: a refusal as not up yet runs `redial` after the next wait, unless
    /// `stillWanted` says otherwise by then (a pause, a disconnect, a connect that already ran, a machine that stopped).
    public func ended(_ error: any Error, machine: CloudMachine, stillWanted: @escaping @MainActor () -> Bool,
                      redial: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = nil
        guard case .notUp? = error as? CloudLinkError, let wait = delay(machine, refusals) else { return }
        refusals += 1
        // task-owner: pending; the one redial of this session, cancelled by the next connect or end
        pending = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            if stillWanted() { redial() }
        }
    }
}

extension CloudMachine {
    /// The status as the person sees it: the API record, except that a connected daemon (`state`) is a running machine. A
    /// create response has no status (decoded as provisioning) and the list is not polled, so the record alone said
    /// "provisioning" after the terminal worked.
    public func effectiveStatus(daemon state: DaemonConnectionState) -> Status {
        guard shownStatus == .provisioning || shownStatus == .unknown, case .connected = state else { return shownStatus }
        return .running
    }
}
