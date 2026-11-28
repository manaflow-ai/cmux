import Foundation
public import os

/// A Cloud start's automatic pick that reused a machine (paused, stuck starting) which never connected: the send plans
/// again with it `unreachable` (`cmux link start-chat plan`), so it takes a new machine or another of the person's
/// instead of ending on "didn't connect". A machine the person chose, or one made for the send, never falls back.
public nonisolated enum CloudStartReuse {
    /// The connect to a reused machine failed (`error`, which the send shows when it cannot fall back).
    public struct Unreachable: Error, CustomStringConvertible {
        public var machine: String, error: any Error
        public var description: String { String(describing: error) }
    }

    /// `error` marked as the reused `machine`'s connect failure (nil: no fallback, the error as it is).
    public static func marked(_ error: any Error, machine: String?) -> any Error {
        guard let machine, !Task.isCancelled else { return error }
        return Unreachable(machine: machine, error: error)
    }

    /// The machine a failed start may plan again without: the connect's own failure (``marked(_:machine:)``), or the
    /// resume or route's failure that names the machine (its Retry moves to it again). Nil: some other failure, which the send keeps.
    public static func unreached(_ error: any Error, machine id: String?) -> String? {
        if Task.isCancelled { return nil }
        if let unreachable = error as? Unreachable { return unreachable.machine }
        guard let id, let failure = error as? CloudMoveFailure, failure.retry?.machineID == id else { return nil }
        return id
    }

    /// The machine the send plans again without (``unreached(_:machine:)``, the reused `id`), logged with why it fell back.
    public static func logged(_ error: any Error, machine id: String?, _ logger: Logger) -> String {
        let machine = unreached(error, machine: id) ?? id ?? ""
        logger.info("cloud start chat: reused machine \(machine, privacy: .public) did not connect (\(String(describing: shown(error)), privacy: .public)); planning without it")
        return machine
    }

    /// The error a send shows when it does not fall back: a marked one's own.
    public static func shown(_ error: any Error) -> any Error { (error as? Unreachable)?.error ?? error }
}
