public import CmuxNextDaemon
import CmuxNextCompat
import Foundation

/// Why a ``DaemonService/type(_:terminal:surface:answered:)`` ended before the daemon took every input.
public nonisolated enum TypedInputFailure: Sendable, Equatable {
    /// The daemon refused the input (or no connection was there), in its words.
    case refused(String)
    /// The input's reply missed its deadline: it may have been written, so it is never sent again.
    case mayNotHaveArrived(String)
}

extension DaemonService {
    /// Writes `inputs` into a terminal from this daemon's connection, in order: text by its host id `terminalID`
    /// when the daemon takes input by terminal id (`send {terminal_id}`, which also reaches a terminal still being
    /// created), else by `surface`; a key by `surface` (`send-key`). The caller passes only inputs it can send: a key
    /// needs a `surface`, text a `surface` or a `terminalID`.
    ///
    /// `answered` runs once on main with how many inputs the daemon took, and why not the input after them (nil: it
    /// took them all). The reason is the daemon's own words (no command label), shown to the person beside the text
    /// they keep. The command starts whether or not a `workTracker` is set, which then tracks it.
    public func type(_ inputs: [TerminalTypedInput], terminal terminalID: TerminalID?, surface: SurfaceID?,
                     answered: @escaping @MainActor @Sendable (_ taken: Int, _ failure: TypedInputFailure?) -> Void) {
        guard !inputs.isEmpty else { return answered(0, nil) }
        let mainWork = mainWork, terminal = terminalID?.rawValue, progress = TypedInputProgress()
        let work = startSend("type-into-terminal", onFailure: { [weak self] failure in
            let (taken, reason) = progress.state.withLock { ($0.taken, $0.reason) }
            let words = reason ?? self?.notConnectedReason ?? DaemonError.notConnected.description
            answered(taken, failure.mayHaveApplied ? .mayNotHaveArrived(words) : .refused(words))
        }) { connection in
            let byID = terminal != nil && connection.identity?.supports(DaemonCapability.terminalInputWhileCreating.rawValue) == true
            for input in inputs {
                do {
                    switch input {
                    case .text(let text):
                        if byID, let terminal {
                            try await connection.sendTerminalInput(terminal, bytes: Data(text.utf8))
                        } else if let surface {
                            try await connection.send(surface, bytes: Data(text.utf8))
                        } else {
                            throw DaemonError.notConnected
                        }
                    case .key(let name):
                        guard let surface else { throw DaemonError.notConnected }
                        try await connection.sendKeys(surface, [name])
                    }
                } catch {
                    progress.state.withLock { $0.reason = Self.words(of: error) }
                    throw error
                }
                progress.state.withLock { $0.taken += 1 }
            }
            mainWork.postFromAnyThread(.userBlocking, owner: "DaemonService.typedInput") { answered(inputs.count, nil) }
        }
        workTracker?(work)
    }

    /// The daemon's own words for `error`: a refusal's message, else the error's description.
    private nonisolated static func words(of error: any Error) -> String {
        if case DaemonError.command(_, let message, _, _, _) = error { return message }
        return (error as? DaemonError)?.description ?? String(describing: error)
    }

    /// Runs `body` once this daemon has its first connection: now when it has one or is not starting (a command
    /// then fails as it would), else when the first connect ends or startup gives up (``firstConnection()``'s
    /// moment), on main. The daemon's own queue for work that needs it before it is there.
    public func onFirstConnection(_ body: @escaping @MainActor () -> Void) {
        guard awaitsFirstConnection else { return body() }
        firstConnectionCallbacks.append(body)
    }

    /// Whether ``onFirstConnection(_:)`` would wait now.
    public var awaitsFirstConnection: Bool { connection == nil && startup == .connecting && isStarting }
}

/// How far one ``DaemonService/type(_:terminal:surface:answered:)`` got: the inputs the daemon took and why the next
/// failed, written on the connection's actor and read on main when it failed.
private nonisolated final class TypedInputProgress: Sendable {
    struct State {
        var taken = 0
        var reason: String?
    }

    let state = Mutex(State())
}
