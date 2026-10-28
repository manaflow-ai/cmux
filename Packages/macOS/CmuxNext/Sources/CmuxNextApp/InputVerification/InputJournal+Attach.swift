import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextInputModel

// Attach state machine transitions into the journal (byte counts only).
extension InputJournal {
    /// Focus transitions between full-state checkpoints of one window.
    nonisolated static let checkpointInterval = 64

    /// A `TerminalAttachDriver` observer that journals every reduction of
    /// `surface`'s attach machine. Runs on the driver's threads.
    nonisolated static func attachObserver<Link>(surface: String) -> TerminalAttachDriver<Link>.Observer {
        { event, machine in
            let journal = InputJournal.shared
            guard journal.isEnabled else { return }
            var record = InputJournalEntry.Attach(surface: surface, event: "", phase: machine.phase.journalName,
                                                  droppedBytes: machine.droppedInputBytes)
            switch event {
            case .start: record.event = "start"
            case .opened(let ref, let attempt):
                record.event = "opened"
                record.link = Self.linkID(ref.link)
                record.attempt = attempt
            case .openFailed(let attempt):
                record.event = "openFailed"
                record.attempt = attempt
            case .replayDelivered(let ref):
                record.event = "replay"
                record.link = Self.linkID(ref.link)
            case .input(let data):
                record.event = "input"
                record.bytes = data.count
            case .resize(let size): record.event = "resize:\(size.cols)x\(size.rows)"
            case .visibility(let visible): record.event = visible ? "visible" : "hidden"
            case .focused: record.event = "focused"
            case .takeOver(let setLatest): record.event = setLatest ? "takeOver:latest" : "takeOver"
            case .gridAnnounced(let ref, let size):
                record.event = "grid:\(size.cols)x\(size.rows)"
                record.link = Self.linkID(ref.link)
            case .ended(let ref, let reason):
                record.event = "ended:\(reason == .overflow ? "overflow" : "other")"
                record.link = Self.linkID(ref.link)
            case .reconnect: record.event = "reconnect"
            case .processExited: record.event = "processExited"
            case .processRevived: record.event = "processRevived"
            case .close: record.event = "close"
            }
            journal.append(window: nil, .attach(record))
        }
    }

    private nonisolated static func linkID(_ link: AnyObject) -> Int { ObjectIdentifier(link).hashValue }
}
