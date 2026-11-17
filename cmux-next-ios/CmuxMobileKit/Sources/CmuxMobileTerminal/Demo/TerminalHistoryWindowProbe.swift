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
/// from the screen, `R` newer rows asked for coming down.
@MainActor
public final class TerminalHistoryWindowProbe {
    public static let shared = TerminalHistoryWindowProbe()

    private var counts: [Character: Int] = [:]
    private var trail = ""
    private let trailLength = 24
    /// The first word of the first row with text on the page when it last
    /// came to rest (a demo row's number).
    var topWord = "-"

    func note(_ event: Character) {
        counts[event, default: 0] += 1
        trail.append(event)
        if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
    }

    /// `top=000123 probe=P3,F0,S0,T0,D0,N0,R0 trail=PPS`: no spaces inside a field.
    public var caption: String {
        let fields = "PFSTDNR".map { "\($0)\(counts[$0] ?? 0)" }.joined(separator: ",")
        return "top=\(topWord) probe=\(fields) trail=\(trail.isEmpty ? "-" : trail)"
    }
}
#endif
