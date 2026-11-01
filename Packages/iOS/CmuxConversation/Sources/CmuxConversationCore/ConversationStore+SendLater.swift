import Foundation

/// A Send Later action the server refused. Messages shows an alert for each
/// (`SCHEDULED_MESSAGE_NOT_RETRACTED_*`, `SCHEDULED_MESSAGE_NOT_EDITED_*`).
public enum ConversationScheduledActionFailure: Sendable, Equatable {
    /// Cancel or delete failed; the scheduled message might still be sent.
    case notCancelled
    /// A new time was refused; the original time stands.
    case notEdited
    /// "Send Message" now failed; the message stays scheduled.
    case notSent
}

/// Send Later: the server holds a message until its time, then sends it as an
/// ordinary message with the same client id, so the transcript row keeps its
/// identity while it turns from outlined (scheduled) to filled (sent).
extension ConversationStore {
    /// Messages lets you schedule up to 14 days ahead.
    nonisolated public static let sendLaterHorizon: TimeInterval = 14 * 24 * 60 * 60

    /// Waiting or failed Send Later messages, earliest first.
    public var scheduledMessages: [ConversationMessage] {
        messages.filter(\.isScheduled)
    }

    /// The time Messages proposes when Send Later is picked: the next whole
    /// hour at least 30 minutes out, or 9 AM the next morning when that falls
    /// at night. Lower-confidence heuristic (no reference capture possible).
    nonisolated public static func defaultSendLaterDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let soon = now.addingTimeInterval(30 * 60)
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: soon)
        components.hour = (components.hour ?? 0) + 1
        let candidate = calendar.date(from: components) ?? soon
        let hour = calendar.component(.hour, from: candidate)
        if hour >= 22 || hour < 7 || !calendar.isDate(candidate, inSameDayAs: now) {
            let base = hour < 7 && calendar.isDate(candidate, inSameDayAs: now) ? now : now.addingTimeInterval(24 * 60 * 60)
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? candidate
        }
        return candidate
    }

    /// "Tomorrow at 9:00 AM": the time shown on the composer chip and above a
    /// scheduled bubble, in the system's relative date style.
    nonisolated public static func sendLaterTimeText(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Appends the outlined row at once, then uploads and queues it on the server.
    @discardableResult
    public func scheduleSend(
        text: String,
        at date: Date,
        images: [(data: Data, width: Int, height: Int, mimeType: String)] = [],
        replyToID: String? = nil,
        mentions: [ConversationMention] = [],
        textRuns: [ConversationTextRun] = [],
        effect: ConversationMessageEffect? = nil
    ) -> String? {
        // Trimmed like a send, with mentions and formatting shifted to match.
        let (trimmed, runs) = ConversationRichText.trimmed(text, runs: textRuns)
        guard (!trimmed.isEmpty || !images.isEmpty), let meID else { return nil }
        let leading = text.prefix { $0.isWhitespace || $0.isNewline }.utf16.count
        let clientID = makeClientMessageID()
        let attachments = images.enumerated().map { offset, image in
            ConversationAttachment(
                id: "local:\(clientID):\(offset)",
                kind: .image,
                width: image.width,
                height: image.height,
                url: nil,
                localData: image.data
            )
        }
        let pending = ConversationMessage(
            id: "local:\(clientID)",
            seq: nil,
            clientMessageID: clientID,
            senderID: meID,
            sentAt: Date(),
            text: trimmed,
            replyToID: replyToID,
            attachments: attachments,
            delivery: .sending,
            mentions: ConversationMentionEditing.trimmed(mentions, removedPrefix: leading, textLength: trimmed.utf16.count),
            textRuns: runs,
            effect: effect,
            scheduledAt: date
        )
        upsert(pending)
        sortAndReindex()
        notify(.live(insertedRowIDs: [pending.rowID], sentByMe: true))
        composerTextChanged(isEmpty: true)
        transmitScheduled(clientID: clientID, images: images)
        return pending.rowID
    }

    /// Edit Time.
    public func reschedule(rowID: String, to date: Date) {
        guard let original = message(rowID: rowID), original.isScheduled,
              let index = indexByID[original.id] else { return }
        messages[index].scheduledAt = date
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: true))
        // Not on the server yet: the pending upload reads the new time.
        guard !original.id.hasPrefix("local:") else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.backend.reschedule(scheduledID: original.id, to: date)
                self.upsert(updated)
                self.sortAndReindex()
            } catch {
                if let index = self.indexByID[original.id] {
                    self.messages[index].scheduledAt = original.scheduledAt
                    self.sortAndReindex()
                }
                self.onScheduledActionFailed?(.notEdited)
            }
            self.notify(.live(insertedRowIDs: [], sentByMe: true))
        }
    }

    /// Delete Message (and Cancel Send Later): removes it at once; restores it
    /// if the server refuses, since it might still be sent.
    public func cancelScheduled(rowID: String) {
        guard let original = message(rowID: rowID), original.isScheduled,
              let index = indexByID[original.id] else { return }
        messages.remove(at: index)
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: true))
        if original.id.hasPrefix("local:") {
            // Its schedule request may still land; cancel that when it does.
            if let clientID = original.clientMessageID, original.delivery?.isFailed != true {
                cancelledScheduleClientIDs.insert(clientID)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.cancelScheduled(scheduledID: original.id)
            } catch {
                if self.indexByID[original.id] == nil,
                   !self.messages.contains(where: { $0.clientMessageID == original.clientMessageID && $0.seq != nil }) {
                    self.upsert(original)
                    self.sortAndReindex()
                    self.notify(.live(insertedRowIDs: [original.rowID], sentByMe: true))
                }
                self.onScheduledActionFailed?(.notCancelled)
            }
        }
    }

    /// Send Message: the server sends it now; the row turns into the sent message.
    public func sendScheduledNow(rowID: String) {
        guard let original = message(rowID: rowID), original.isScheduled,
              let index = indexByID[original.id] else { return }
        if original.id.hasPrefix("local:") {
            messages[index].scheduledAt = Date()
            notify(.live(insertedRowIDs: [], sentByMe: true))
            if original.delivery?.isFailed == true, let clientID = original.clientMessageID {
                retransmitScheduled(clientID: clientID, index: index)
            }
            return
        }
        messages[index].delivery = .sending
        notify(.live(insertedRowIDs: [], sentByMe: true))
        Task { [weak self] in
            guard let self else { return }
            do {
                var sent = try await self.backend.sendScheduledNow(scheduledID: original.id)
                if sent.delivery == nil { sent.delivery = .sent }
                self.upsert(sent)
                self.sortAndReindex()
            } catch {
                if let index = self.indexByID[original.id], self.messages[index].isScheduled {
                    self.messages[index].delivery = original.delivery
                }
                self.onScheduledActionFailed?(.notSent)
            }
            self.notify(.live(insertedRowIDs: [], sentByMe: true))
        }
    }

    /// Try Again on a scheduled message that will not send: schedule it again
    /// at its time, or send it now when that time has passed.
    public func retryScheduled(rowID: String, now: Date = Date()) {
        guard let original = message(rowID: rowID), original.isScheduled,
              original.delivery?.isFailed == true,
              let index = indexByID[original.id], let scheduledAt = original.scheduledAt else { return }
        if original.id.hasPrefix("local:"), let clientID = original.clientMessageID {
            retransmitScheduled(clientID: clientID, index: index)
        } else if scheduledAt > now {
            messages[index].delivery = .sending
            reschedule(rowID: rowID, to: scheduledAt)
        } else {
            sendScheduledNow(rowID: rowID)
        }
    }

    private func retransmitScheduled(clientID: String, index: Int) {
        messages[index].delivery = .sending
        notify(.live(insertedRowIDs: [], sentByMe: true))
        let images = messages[index].attachments.compactMap { attachment -> (data: Data, width: Int, height: Int, mimeType: String)? in
            guard attachment.kind == .image, let data = attachment.localData else { return nil }
            return (data, attachment.width, attachment.height, "image/jpeg")
        }
        transmitScheduled(clientID: clientID, images: images)
    }

    private func transmitScheduled(clientID: String, images: [(data: Data, width: Int, height: Int, mimeType: String)]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                var attachmentIDs: [String] = []
                for image in images {
                    attachmentIDs.append(try await self.backend.uploadImage(image.data, mimeType: image.mimeType).id)
                }
                guard let current = self.messages.first(where: { $0.clientMessageID == clientID && $0.isScheduled }),
                      let date = current.scheduledAt else {
                    if self.cancelledScheduleClientIDs.contains(clientID) { self.cancelledScheduleClientIDs.remove(clientID) }
                    return
                }
                let draft = ConversationOutgoingDraft(
                    clientMessageID: clientID,
                    text: current.text,
                    replyToID: current.replyToID,
                    attachmentIDs: attachmentIDs,
                    mentions: current.mentions,
                    textRuns: current.textRuns,
                    effect: current.effect
                )
                // A time picked in the past (or reached while uploading) sends at once.
                let acked = try await self.backend.scheduleSend(draft, at: max(date, Date()))
                if self.cancelledScheduleClientIDs.remove(clientID) != nil {
                    try? await self.backend.cancelScheduled(scheduledID: acked.id)
                    return
                }
                self.upsert(acked)
                self.sortAndReindex()
                self.notify(.live(insertedRowIDs: [], sentByMe: true))
            } catch {
                guard self.cancelledScheduleClientIDs.remove(clientID) == nil,
                      let index = self.messages.firstIndex(where: { $0.clientMessageID == clientID && $0.isScheduled }) else { return }
                self.messages[index].delivery = .failed(String(describing: error))
                self.notify(.live(insertedRowIDs: [], sentByMe: true))
            }
        }
    }

    /// `scheduled.removed`: drop the row unless it already became the sent message.
    func removeScheduledRow(id: String, clientMessageID: String?) {
        let index = indexByID[id] ?? clientMessageID.flatMap { clientID in
            messages.firstIndex { $0.clientMessageID == clientID && $0.isScheduled }
        }
        guard let index, messages[index].isScheduled else { return }
        messages.remove(at: index)
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: false))
    }

    /// Reloads the server's queue on every (re)connect. Rows that appeared
    /// while the request was out stay; rows the server no longer has go.
    func refreshScheduled() {
        scheduledRefreshTask?.cancel()
        let knownBefore = Set(messages.filter { $0.isScheduled && !$0.id.hasPrefix("local:") }.map(\.id))
        scheduledRefreshTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let list = try await self.backend.scheduledMessages()
                    guard !Task.isCancelled else { return }
                    let serverIDs = Set(list.map(\.id))
                    var changed = false
                    for stale in knownBefore.subtracting(serverIDs) {
                        if let index = self.indexByID[stale], self.messages[index].isScheduled {
                            self.messages.remove(at: index)
                            self.sortAndReindex()
                            changed = true
                        }
                    }
                    var inserted: [String] = []
                    for message in list where self.upsert(message) {
                        inserted.append(message.rowID)
                    }
                    if changed || !list.isEmpty {
                        self.sortAndReindex()
                        self.notify(.live(insertedRowIDs: inserted, sentByMe: false))
                    }
                    return
                } catch let error as ConversationBackendError where error.code == -32601 {
                    return
                } catch {
                    attempt += 1
                    guard attempt < 6 else { return }
                    try? await self.clock.sleep(for: Self.backoff(attempt))
                }
            }
        }
    }
}
