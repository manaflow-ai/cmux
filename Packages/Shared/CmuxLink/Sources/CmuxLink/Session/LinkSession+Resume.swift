import Foundation

/// Replay after a transport switch and epoch resets (a3-link.md section 5).
extension LinkSession {
    /// Sends what the peer is missing on a reliable channel: a `gap` when its
    /// cursor is below what this side still retains (or from another epoch),
    /// then every retained message above the cursor.
    func resumeOutbound(_ id: UInt32, peerEpoch: UInt64, peerRevision: UInt64) {
        guard var record = channels[id], record.descriptor.reliability.isReliable else { return }
        let lastSent = record.nextRevision - 1
        let floor = record.retained.first?.revision ?? (lastSent + 1)
        let sameEpoch = peerEpoch == epoch
        var replayAfter = peerRevision
        if sameEpoch, peerRevision + 1 >= floor, peerRevision <= lastSent {
            // The peer has everything up to its cursor: those are acknowledged.
            let covered = record.retained.prefix { $0.revision <= peerRevision }
            record.retainedBytes -= covered.reduce(0) { $0 + $1.payload.count }
            record.retained.removeFirst(covered.count)
            channels[id] = record
            releaseCredit(id)
        } else if peerRevision > 0 || !sameEpoch && lastSent > 0 {
            let reason: GapReason = sameEpoch ? .retentionExceeded : .newEpoch
            replayAfter = floor - 1
            enqueueChannelControl(id, frame: .gap(channel: id, resumeAfter: replayAfter, reason: reason))
        }
        let pending = channels[id]?.retained ?? []
        for message in pending where message.revision > replayAfter {
            // Head-of-line: a frame the path cannot carry stalls the rest.
            guard enqueueData(id, revision: message.revision, payload: message.payload) else { break }
        }
    }

    /// The host started a new epoch: nothing from the old one can be resumed.
    /// Inbound directions report a gap, outbound numbering restarts, and
    /// channels the old host session opened end.
    func resetForNewEpoch() {
        highestPeerChannelID = 0
        for id in channels.keys.sorted() {
            guard var record = channels[id] else { continue }
            if !record.openedLocally {
                endChannel(id, reason: .remote, error: LinkError.channelClosed)
                continue
            }
            let hadTraffic = record.lastReceived > 0 || record.nextRevision > 1
            let stream = record.descriptor.stream
            let previous = StreamCursor(stream: stream, epoch: record.cursorEpoch, revision: record.lastReceived)
            record.retained.removeAll()
            record.retainedBytes = 0
            record.nextRevision = 1
            record.lastReceived = 0
            record.lastConsumed = 0
            record.cursorEpoch = 0
            let credit = record.creditWaiters.values
            let flush = record.flushWaiters.values
            record.creditWaiters.removeAll()
            record.flushWaiters.removeAll()
            channels[id] = record
            for waiter in credit { waiter.resume() }
            for waiter in flush { waiter.resume() }
            if hadTraffic, !record.isClosed {
                deliver(id, .gap(ChannelGap(
                    lastDelivered: previous,
                    resumedAfter: StreamCursor(stream: stream, epoch: 0, revision: 0),
                    reason: .newEpoch
                )))
            }
        }
    }
}
