import CmuxNextBridge
import Foundation

/// Checks one terminal attach machine's reductions against the attach
/// invariants A1-A4 (plans/cmux-next/input-spec.md section 2.3). Feed it
/// every event with the machine before and after and the effects returned;
/// it keeps the accepted input and the sends, so "lost, duplicated or
/// reordered" is decided exactly, not by sampling.
nonisolated struct AttachOracle<Link: Hashable & Sendable>: Sendable {
    typealias Machine = TerminalAttachMachine<Link>

    /// Input the machine accepted (sent or queued), oldest first, not yet sent.
    private(set) var unsent: [Data] = []
    private(set) var sentChunks = 0
    private(set) var droppedChunks = 0
    /// Links the machine was told about (`opened`), and their detach counts.
    private(set) var detaches: [Link: Int] = [:]
    /// `open` effects not yet answered by `opened` or `openFailed`.
    private(set) var openAttempts: Set<Int> = []

    init() {}

    /// Checks one reduction. Returns the broken invariants.
    mutating func observe(_ event: Machine.Event, before: Machine, after: Machine, effects: [Machine.Effect],
                          window: String? = nil, surface: String = "") -> [InputViolation] {
        var out: [InputViolation] = []
        func fail(_ invariant: InputInvariant, _ detail: String) {
            out.append(InputViolation(invariant: invariant, window: window, detail: "\(surface) \(detail) after \(Self.name(event))"))
        }
        switch event {
        case .opened(let link, let attempt):
            openAttempts.remove(attempt)
            if detaches[link] == nil { detaches[link] = 0 }
        case .openFailed(let attempt):
            openAttempts.remove(attempt)
        case .input(let data) where !data.isEmpty:
            let dropped = after.droppedInputBytes - before.droppedInputBytes
            if dropped == data.count {
                droppedChunks += 1
                let overCap = before.queuedInputBytes + data.count > Machine.maxQueuedInputBytes
                if !before.isClosed, !overCap, before.liveLink == nil {
                    fail(.inputOrder, "dropped \(data.count) bytes while attaching under the queue cap")
                }
                if before.liveLink != nil { fail(.inputOrder, "dropped \(data.count) bytes on a live link") }
            } else if dropped == 0 {
                unsent.append(data)
            } else {
                fail(.inputOrder, "dropped \(dropped) of \(data.count) bytes")
            }
        default:
            break
        }
        for effect in effects {
            switch effect {
            case .open(let attempt, _):
                openAttempts.insert(attempt)
            case .send(let link, let data):
                if after.isClosed { fail(.closedIsFinal, "sent after close") }
                if detaches[link, default: 0] > 0 { fail(.liveLinkOnly, "sent on a detached link") }
                if after.liveLink != link { fail(.liveLinkOnly, "sent on a link that is not live (\(after.phase.journalName))") }
                if let next = unsent.first, next == data {
                    unsent.removeFirst()
                    sentChunks += 1
                } else {
                    fail(.inputOrder, "sent \(data.count) bytes out of order or twice (next accepted: \(unsent.first?.count ?? -1) bytes)")
                }
            case .claim(let link, _), .release(let link):
                if detaches[link, default: 0] > 0 { fail(.liveLinkOnly, "geometry on a detached link") }
            case .detach(let link):
                let count = detaches[link, default: 0] + 1
                detaches[link] = count
                if count > 1 { fail(.detachOnce, "link detached \(count) times") }
            case .finish:
                break
            }
        }
        if after.isClosed {
            if !after.queuedInput.isEmpty { fail(.closedIsFinal, "closed with queued input") }
            // What was still unsent is dropped with the close.
            if !unsent.isEmpty {
                droppedChunks += unsent.count
                unsent.removeAll()
            }
            if openAttempts.isEmpty {
                for (_, count) in detaches where count != 1 { fail(.detachOnce, "closed with a link detached \(count) times") }
            }
        } else if after.queuedInput != unsent {
            fail(.inputOrder, "queue \(after.queuedInput.map(\.count)) != accepted unsent \(unsent.map(\.count))")
        }
        return out
    }

    static func name(_ event: Machine.Event) -> String {
        switch event {
        case .start: "start"
        case .opened(_, let attempt): "opened(\(attempt))"
        case .openFailed(let attempt): "openFailed(\(attempt))"
        case .replayDelivered: "replay"
        case .input(let data): "input(\(data.count))"
        case .resize(let size): "resize(\(size.cols)x\(size.rows))"
        case .visibility(let visible): visible ? "visible" : "hidden"
        case .focused: "focused"
        case .gridAnnounced(_, let size): "grid(\(size.cols)x\(size.rows))"
        case .ended(_, let reason): "ended(\(reason))"
        case .close: "close"
        }
    }
}
