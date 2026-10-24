import Foundation

/// Each terminal's foreground program (`terminal-foreground-v1`), kept by surface: seeded at
/// connect (``ListTerminalForegroundsRequest``) and updated by `terminal-foreground-changed`. A
/// close reads it in the key's turn to decide whether to ask (no daemon read on the input path).
public struct TerminalForegrounds: Sendable {
    public private(set) var bySurface: [SurfaceID: TerminalForeground] = [:]

    public init() {}

    /// Applies one change; false (and nothing changes) when it is not newer than the one held:
    /// an event held across a resync can arrive after the connect seed.
    @discardableResult
    public mutating func apply(_ foreground: TerminalForeground) -> Bool {
        if let held = bySurface[foreground.surface], foreground.seq <= held.seq { return false }
        bySurface[foreground.surface] = foreground
        return true
    }

    /// Replaces every surface's state with `list`, keeping a held one that is newer.
    public mutating func seed(_ list: [TerminalForeground]) {
        var seeded: [SurfaceID: TerminalForeground] = [:]
        for foreground in list {
            if let held = bySurface[foreground.surface], held.seq > foreground.seq {
                seeded[foreground.surface] = held
            } else {
                seeded[foreground.surface] = foreground
            }
        }
        bySurface = seeded
    }

    /// `surface`'s foreground program other than its shell, else nil.
    public func runningProgram(_ surface: SurfaceID) -> String? {
        bySurface[surface]?.runningProgram
    }
}
