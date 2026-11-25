// DEBUG and Demo builds only: never compiled into Production.
#if DEBUG
import Foundation

/// DEBUG only. What the terminal screen did with a reader's place across
/// history fetches, for `TerminalHistoryWindowDemo`'s caption (the UI test's
/// simulator is deleted before its app log is read). Each event is counted
/// and appended, one letter, to a short trail:
/// `P` a reading mark placed, `F` placed under a finger, `S` a replay read as short of the reader (older
/// rows asked), `T` a restore dropped because a finger or a fling held the
/// page, `D` a waiting place dropped by a drag, `N` the newest rows asked for
/// from the screen, `R` newer rows asked for coming down. At a reset: `M` the
/// reader's rows marked, `W` a place already waiting kept, `Z` nothing marked
/// (the page follows). `G` the page reached a restore's rows.
@MainActor
public final class TerminalHistoryWindowProbe {
    public static let shared = TerminalHistoryWindowProbe()

    private var counts: [Character: Int] = [:]
    private var trail = ""
    private let trailLength = 24
    /// The first word of the first row with text on the page when it last
    /// came to rest (a demo row's number).
    var topWord = "-"
    /// The last restore: the scroll state at the report (`f` following, `r`
    /// reading, `h` a held gesture, `i` interacting), the rows the page moved
    /// since the mark, then `@anchor/total`.
    var lastPlace = "-"
    /// When the newest rows were last asked for: the rows on the page, the
    /// gap's row, the document's rows, and the restore before it.
    var lastNewest = "-"
    /// The last reset: the scroll state (`f`, `r`, `i`), `u` when a restore
    /// had not reached its rows yet, `t` a finger or `d` a deceleration on
    /// the page, `:` then the outcome letter and, for `Z`, why (`anchor`: no
    /// rows away from the bottom, `text`: the rows did not read, `glide`).
    var lastReset = "-"
    /// The last reset that marked nothing (`Z`), as `lastReset` reads it:
    /// kept, since the resets after it overwrite `lastReset`.
    var lastMiss = "-"
    /// The last restore under a gesture (`applyFingerRestore`): the reader's
    /// row, the row the page was set to and the last row it could be, `d` a
    /// deceleration or `t` a finger, `>` then the scroll state after it
    /// (`f`, `r`, `i`, `u` while the page has not reached the rows), or `x`
    /// and why it placed nothing.
    var lastFinger = "-"

    func note(_ event: Character) {
        counts[event, default: 0] += 1
        trail.append(event)
        if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
    }

    /// `top=000123 probe=P3,F0,K0,S0,T0,D0,N0,R0 trail=PPS place=f+0@1530/4051 newest=-`: no spaces inside a field.
    /// `K`: the restore found the reader's rows but the scroll model kept another state.
    /// `U`: a drag began before the page reached the restored rows; it was moved there first.
    /// `I`: while the page had not reached a restore's rows, it was moved to
    /// the frame it had (`applyScroll`'s interim offset) to wait for theirs.
    public var caption: String {
        let fields = "PFKUSTDNRMWZGI".map { "\($0)\(counts[$0] ?? 0)" }.joined(separator: ",")
        return "top=\(topWord) probe=\(fields) trail=\(trail.isEmpty ? "-" : trail) place=\(lastPlace) newest=\(lastNewest) reset=\(lastReset) miss=\(lastMiss) finger=\(lastFinger)"
    }
}
#endif
