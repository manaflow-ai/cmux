import Foundation

/// Each terminal's foreground program (`terminal-foreground-v1`), kept by surface: seeded once per
/// connection (``ListTerminalForegroundsRequest``) and updated by `terminal-foreground-changed`. A
/// close reads it in the key's turn to decide whether to ask (no daemon read on the input path).
///
/// It answers only what it knows: before this connection's seed, or for a surface with no entry,
/// ``programs(of:epoch:)`` gives nil and the caller asks the daemon (a close never skips its
/// question because the state was not here yet).
public struct TerminalForegrounds: Sendable {
    public private(set) var bySurface: [SurfaceID: TerminalForeground] = [:]
    /// The connection (``DaemonStore/connectionEpoch``) whose seed the entries come from; nil
    /// before a seed or after the connection changed.
    public private(set) var seededEpoch: Int?

    public init() {}

    /// Applies one change; false (and nothing changes) when it is not newer than the one held
    /// for this connection: an event held across the seed can arrive after it.
    @discardableResult
    public mutating func apply(_ foreground: TerminalForeground) -> Bool {
        if let held = bySurface[foreground.surface], foreground.seq <= held.seq { return false }
        bySurface[foreground.surface] = foreground
        return true
    }

    /// Replaces every entry with `list`, the daemon's state for connection `epoch`. Events after the
    /// list was read apply on top through ``apply(_:)``.
    public mutating func seed(_ list: [TerminalForeground], epoch: Int) {
        bySurface = Dictionary(list.map { ($0.surface, $0) }, uniquingKeysWith: { $0.seq >= $1.seq ? $0 : $1 })
        seededEpoch = epoch
    }

    /// The connection changed (a reconnect, a daemon restart whose surfaces keep their ids but
    /// start their sequence again, a disconnect): nothing held is known any more.
    public mutating func reset() {
        bySurface = [:]
        seededEpoch = nil
    }

    /// `surface` closed: its entry goes (a surface that comes back gets an event or is asked).
    public mutating func forget(_ surface: SurfaceID) {
        bySurface[surface] = nil
    }

    /// Each of `surfaces`' foreground program other than its shell (nil: its shell only), when
    /// every one of them is known for connection `epoch`; else nil (ask the daemon).
    public func programs(of surfaces: [SurfaceID], epoch: Int) -> [SurfaceID: String?]? {
        guard seededEpoch == epoch else { return nil }
        var programs: [SurfaceID: String?] = [:]
        for surface in surfaces {
            guard let held = bySurface[surface] else { return nil }
            programs[surface] = .some(held.runningProgram)
        }
        return programs
    }
}
