import Foundation

// HomeStore's owner traffic: submitting intents, resends after a reconnect,
// applying owner events, and refetching after a gap.
extension HomeStore {
    // MARK: Internals

    /// `passing`: a refusal the caller handles itself (the log and the
    /// send queue stay as they are).
    func submit(_ intent: HomeIntent, passing: HomeRejection? = nil) async throws -> HomeOpResult {
        noteSubmitted(intent.key)
        do {
            let result = try await source.submit(intent)
            cancelBackoff(intent.key)
            endOfflineDeadline(intent.key)
            log.acknowledge(intent.key, rev: result.rev)
            uploads[intent.key] = nil
            leaveSendQueue(intent.key)
            settle()
            afterLogChange(intent.op)
            return result
        } catch let rejection as HomeRejection {
            switch rejection {
            case .ownerUnreachable, .indeterminate:
                possiblySent.insert(intent.key)
                // Possibly committed: keep it and resend with the same key.
                // Online: once at once, then after each backoff delay,
                // then "Not Delivered" so later sends are not held forever.
                log.markUnconfirmed(intent.key)
                if isOnline {
                    if let again = log.takeImmediateResend(intent.key) {
                        enqueueResends([again])
                    } else if !scheduleBackoff(intent.key, .resend) {
                        giveUp(intent.key, rejection, reachedOwner: true)
                        throw HomeSendState.unanswered
                    }
                }
                afterLogChange(intent.op)
                throw HomeSendState.pendingResend
            default:
                if rejection == passing { throw rejection }
                // A resend or retry the owner cannot match to its uploads
                // (swept while the answer was lost): upload again, once.
                if rejection == Self.swept, case .sendMessage = intent.op, let next = uploadAgainAfterSweep(intent.key) {
                    afterLogChange(intent.op)
                    resumeUpload(next)
                    throw HomeSendState.pendingResend
                }
                cancelBackoff(intent.key)
                endOfflineDeadline(intent.key)
                leaveSendQueue(intent.key)
                if case .sendMessage = intent.op {
                    log.fail(intent.key, rejection)
                } else {
                    log.discard(intent.key)
                }
                afterLogChange(intent.op)
                throw rejection
            }
        } catch is HomeOwnerOffline {
            // Nothing left: its owner is down while another owner keeps the
            // store online. A send waits for its recovery, as offline.
            guard case .sendMessage = intent.op else {
                log.discard(intent.key)
                afterLogChange(intent.op)
                throw HomeRejection.ownerUnreachable
            }
            waitForOwnerRecovery(intent.key)
            afterLogChange(intent.op)
            throw HomeSendState.pendingResend
        }
    }

    /// Resends run one at a time, in log order, so the owner sees them in
    /// order. A send also waits for every earlier send of its conversation
    /// (a send with attachments made while offline uploads first).
    func enqueueResends(_ intents: [HomeIntent]) {
        pendingResends.append(contentsOf: intents)
        guard resendTask == nil, !pendingResends.isEmpty else { return }
        resendTask = Task { [weak self] in
            while let self, !self.pendingResends.isEmpty, !self.stopped {
                let next = self.pendingResends.removeFirst()
                // Cancelled or dropped since it was queued.
                guard self.log.entries.contains(where: { $0.intent.key == next.key }) else { continue }
                if case .sendMessage(let conversation, _) = next.op {
                    await self.waitForTurn(next.key, in: conversation)
                    guard self.log.entries.contains(where: { $0.intent.key == next.key }), !self.stopped else { continue }
                }
                do {
                    _ = try await self.submit(next)
                } catch let rejection as HomeRejection {
                    // Nobody awaits a resend: the host hears of the refusal.
                    self.reportRefusal(next, rejection)
                } catch {}
            }
            self?.resendTask = nil
        }
    }

    func handle(_ event: HomeEvent) {
        switch event {
        case .connection(let state):
            let wasOnline = connection == .online
            connection = state
            if state != .online {
                log.markDisconnected()
                pendingResends.removeAll()
                cancelBackoffs()
            }
            if state == .online, !wasOnline {
                backoffAttempts.removeAll()
                enqueueResends(log.takeResends())
                resumeInterruptedUploads()
                for stream in mirror.stale { scheduleRefetch(stream) }
            }
            rebuildRows()
        case .ownerRecovered:
            // Offline intents wait for the reconnect, which resends them anyway.
            guard isOnline else { return }
            enqueueResends(log.takeResends())
            resumeInterruptedUploads()
            for stream in mirror.stale { scheduleRefetch(stream) }
            rebuildRows()
        case .intentsRevoked(let keys):
            // A resend already queued must not go either; one in flight is refused by its owner.
            pendingResends.removeAll { keys.contains($0.key) }
            for op in log.revoke(keys) {
                if let id = op.conversation { bumpTranscript(id) }
            }
            rebuildRows()
        case .typing(let id, let who, let on):
            var set = typing[id] ?? []
            if on { set.insert(who) } else { set.remove(who) }
            typing[id] = set.isEmpty ? nil : set
            rebuildRows()
        default:
            let outcome = mirror.apply(event)
            switch event {
            case .inbox(let snapshot):
                me = snapshot.me
                log.dropIntents(outside: Set(mirror.conversations.keys))
                dropOrphanUploadJobs()
                for stream in mirror.stale { scheduleRefetch(stream) }
            case .conversationRemoved:
                log.dropIntents(outside: Set(mirror.conversations.keys))
                dropOrphanUploadJobs()
            case .message(let message, _):
                bumpTranscript(message.conversation)
            case .conversationPage(let page):
                bumpTranscript(page.conversation.id)
            default:
                break
            }
            settle()
            rebuildRows()
            if case .gap(let stream) = outcome { scheduleRefetch(stream) }
        }
    }

    private func scheduleRefetch(_ stream: HomeStream) {
        guard !stopped else { return }
        switch stream {
        case .inbox:
            guard !refetching.contains(stream) else { return }
            Task { await self.refetchInbox() }
        case .conversation(let id):
            load(id)
        }
    }

    /// Fetches the inbox. A failure leaves it stale; the next reconnect
    /// fetches it again.
    private func refetchInbox() async {
        let stream = HomeStream.inbox
        guard !refetching.contains(stream), !stopped else { return }
        refetching.insert(stream)
        defer { refetching.remove(stream) }
        guard let snapshot = try? await source.inbox() else { mirror.markStale(stream); return }
        let behind = mirror.apply(inbox: snapshot)
        me = snapshot.me
        settle()
        rebuildRows()
        for next in behind { scheduleRefetch(next) }
    }
}
