public import CmuxNextDaemon
import CmuxNextCompat
import Foundation

extension DaemonService {
    /// Writes `inputs` into a terminal from this daemon's connection, in order: text by its host id `terminalID`
    /// when the daemon takes input by terminal id (`send {terminal_id}`, which also reaches a terminal still being
    /// created), else by `surface`; a key by `surface` (`send-key`). The caller passes only inputs it can send: a key
    /// needs a `surface`, text a `surface` or a `terminalID`.
    ///
    /// `answered` runs once on main with how many inputs the daemon took (or may have: a reply past its deadline is
    /// never sent again), and why not the rest (nil: it took them all). The reason is logged and shown to the person
    /// beside the text they keep.
    public func type(_ inputs: [TerminalTypedInput], terminal terminalID: TerminalID?, surface: SurfaceID?,
                     answered: @escaping @MainActor @Sendable (_ taken: Int, _ refusal: String?) -> Void) {
        guard !inputs.isEmpty else { return answered(0, nil) }
        let mainWork = mainWork, terminal = terminalID?.rawValue, taken = TakenInputs()
        send("type-into-terminal", onFailure: { failure in
            // The input whose reply missed its deadline may have been written: it counts as taken.
            let count = min(taken.count.withLock { $0 } + (failure.mayHaveApplied ? 1 : 0), inputs.count)
            answered(count, count == inputs.count ? nil : failure.message)
        }) { connection in
            let byID = terminal != nil && connection.identity?.supports(DaemonCapability.terminalInputWhileCreating.rawValue) == true
            for input in inputs {
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
                taken.count.withLock { $0 += 1 }
            }
            mainWork.postFromAnyThread(.userBlocking, owner: "DaemonService.typedInput") { answered(inputs.count, nil) }
        }
    }

    /// Runs `body` once this daemon has its first connection: now when it has one or is not starting (a command
    /// then fails as it would), else when the first connect ends or startup gives up (``firstConnection()``'s
    /// moment), on main. The daemon's own queue for work that needs it before it is there.
    public func onFirstConnection(_ body: @escaping @MainActor () -> Void) {
        guard connection == nil, startup == .connecting, isStarting else { return body() }
        firstConnectionCallbacks.append(body)
    }

    /// Whether ``onFirstConnection(_:)`` would wait now.
    public var awaitsFirstConnection: Bool { connection == nil && startup == .connecting && isStarting }
}

/// How many inputs of one ``DaemonService/type(_:terminal:surface:answered:)`` the daemon took, counted on the
/// connection's actor and read on main when it failed.
private nonisolated final class TakenInputs: Sendable {
    let count = Mutex(0)
}
