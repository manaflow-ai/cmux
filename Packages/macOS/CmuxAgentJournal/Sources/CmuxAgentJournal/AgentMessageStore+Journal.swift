import Foundation

/// The store's journal file: encoding, replay on open, and compaction. Must
/// hold `lock` for every method except during `init`.
extension AgentMessageStore {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Appends one JSON line to the journal, creating the file when it doesn't
    /// exist. A failed write is truncated back off the file so a partial line
    /// can't swallow the next record. In-memory stores write nothing.
    /// Must hold `lock`.
    func appendRecord(_ record: Record) throws {
        guard let fileURL else { return }
        var data = try Self.encoder.encode(record)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Never fall back to rewriting an existing file: a failed open
            // (out of descriptors, permissions) fails this write, not history.
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            do {
                try handle.write(contentsOf: data)
            } catch {
                try? handle.truncate(atOffset: offset)
                throw error
            }
        } else {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    func load(from fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? Self.decoder.decode(Record.self, from: Data(line)) else { continue }
            switch record.kind {
            case .message:
                guard let message = record.message, messagesById[message.id] == nil else { continue }
                messagesById[message.id] = message
                order.append(message.id)
            case .state:
                guard let id = record.id,
                      let state = record.state,
                      var message = messagesById[id],
                      message.state.canAdvance(to: state) else { continue }
                Self.apply(
                    state: state,
                    at: record.at ?? message.createdAt,
                    via: record.via,
                    reason: record.reason,
                    to: &message
                )
                messagesById[id] = message
            case .recipient:
                guard let id = record.id, let scope = record.scope, let enabled = record.enabled else { continue }
                applyRecipientSetting(enabled: enabled, scope: scope, id: id, capping: false)
            }
        }
        trimOptOuts()
        if order.count > Self.compactionThreshold {
            compact(to: fileURL)
        }
    }

    /// Rewrites the file with the newest retained read or failed messages,
    /// every queued or delivered message in its current state, and the
    /// current recipient opt-outs. The in-memory state changes only after the
    /// atomic file write succeeds. `force` rewrites even when no message is
    /// dropped, which folds repeated opt-out records into one each.
    func compact(to fileURL: URL, force: Bool = false) {
        let excess = max(order.count - Self.retainedMessageCount, 0)
        guard excess > 0 || force else {
            recordsSinceCompaction = 0
            return
        }
        var remaining = excess
        var kept: [String] = []
        kept.reserveCapacity(order.count)
        for id in order {
            if remaining > 0, let message = messagesById[id], message.state == .read || message.state == .failed {
                remaining -= 1
                continue
            }
            kept.append(id)
        }
        var data = Data()
        for id in kept {
            guard let message = messagesById[id],
                  let line = try? Self.encoder.encode(Record(kind: .message, message: message)) else {
                return
            }
            data.append(line)
            data.append(0x0A)
        }
        for optOut in optOutOrder {
            guard let line = try? Self.encoder.encode(
                Record(kind: .recipient, id: optOut.id, scope: optOut.scope, enabled: false)
            ) else { return }
            data.append(line)
            data.append(0x0A)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let keptIDs = Set(kept)
        for id in order where !keptIDs.contains(id) {
            messagesById.removeValue(forKey: id)
        }
        order = kept
        deferredLeases = deferredLeases.filter { _, lease in
            lease.messageIDs.allSatisfy { keptIDs.contains($0) && messagesById[$0] != nil }
        }
        recordsSinceCompaction = 0
    }
}
