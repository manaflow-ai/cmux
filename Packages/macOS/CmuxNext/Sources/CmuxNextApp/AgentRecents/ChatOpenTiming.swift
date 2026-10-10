import Foundation

/// One Open Chat from a click to its outcome (cx-tr0w): when the daemon's plan came back and when
/// the route finished (the workspace made, the tab revealed), or which guard stopped it. Read
/// through `debug.timings` `chat_opens`, so a slow or silent click names its step.
@MainActor
final class ChatOpenTiming {
    let key: String
    private let start = ContinuousClock.now
    private(set) var marks: [(name: String, duration: Duration)] = []
    private var ended = false

    init(key: String) { self.key = key }

    func mark(_ name: String) { marks.append((name, ContinuousClock.now - start)) }

    /// Records the outcome once; later calls are ignored.
    func end(_ outcome: String) {
        guard !ended else { return }
        ended = true
        DebugTimings.chatOpened(key: key, outcome: outcome, marks: marks, total: ContinuousClock.now - start)
    }
}
