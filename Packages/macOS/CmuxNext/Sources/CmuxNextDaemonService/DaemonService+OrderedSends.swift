public import CmuxNextActions
public import CmuxNextDaemon

extension DaemonService {
    /// Sends `body` once every earlier ordered send to terminal `surface` has ended, so input sent this way reaches the
    /// terminal in the order it was sent, also when one send makes several requests (text, then a key) and a later one
    /// would otherwise run between them (P0 1193: held keys for a terminal whose view is gone). The ticket opens now,
    /// as ``send(_:_:)``'s does; a failure is logged as there, and the next send still runs.
    public func sendInOrder(_ label: String, to surface: SurfaceID, _ body: @escaping DaemonCommandBody) {
        let ticket = openTicket(label), previous = orderedSends[surface]?.work
        orderedSendSerial += 1
        let serial = orderedSendSerial
        // task-owner: one ordered send; the next send to this surface awaits it, and the last one clears the entry. It
        // keeps the service alive as `send(_:_:)` does, so its ticket always closes and a gone connection is reported
        // ("not connected"), never a silent success with the keys lost.
        let work: ActionWork = Task {
            _ = await previous?.value
            let failed = await failure(label, ticket: ticket, body)
            if orderedSends[surface]?.serial == serial { orderedSends[surface] = nil }
            return failed
        }
        orderedSends[surface] = (serial, work)
        workTracker?(work)
    }
}
