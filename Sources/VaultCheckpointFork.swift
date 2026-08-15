import Foundation

enum VaultCheckpointForkError: Error, Equatable {
    case parentMissing
    case invalidSessionID
    case anchorNotFound
    case emptyFork
    case byteCapExceeded
    case readFailed
    case writeFailed

    /// Short, product-language description safe to show in the UI; internal
    /// detail belongs in logs, not error banners.
    var localizedSummary: String {
        switch self {
        case .parentMissing:
            return String(localized: "sessionIndex.checkpoints.error.parentMissing",
                          defaultValue: "The original transcript file is missing")
        case .invalidSessionID:
            return String(localized: "sessionIndex.checkpoints.error.invalidSessionID",
                          defaultValue: "The new session id is invalid")
        case .anchorNotFound:
            return String(localized: "sessionIndex.checkpoints.error.anchorNotFound",
                          defaultValue: "This checkpoint no longer matches the transcript")
        case .emptyFork:
            return String(localized: "sessionIndex.checkpoints.error.emptyFork",
                          defaultValue: "There is nothing before this checkpoint to fork")
        case .byteCapExceeded:
            return String(localized: "sessionIndex.checkpoints.error.byteCapExceeded",
                          defaultValue: "The transcript is too large to fork")
        case .readFailed:
            return String(localized: "sessionIndex.checkpoints.error.readFailed",
                          defaultValue: "Couldn't read the original transcript")
        case .writeFailed:
            return String(localized: "sessionIndex.checkpoints.error.writeFailed",
                          defaultValue: "Couldn't write the forked transcript")
        }
    }
}

/// Creates a new Claude Code session file by copying the parent transcript up
/// to a checkpoint under a FRESH session id. The parent file is never touched;
/// divergence happens entirely in the new session (issue #10156 class: every
/// copied line carries the new id, and identity is the minted UUID — never
/// inferred from process state).
enum VaultCheckpointForker {
    /// Hard cap on how much parent transcript a fork may stream.
    nonisolated static let maxForkBytes = 64 * 1024 * 1024
    private static let newlineByte: UInt8 = 0x0a

    /// Streams the parent JSONL line-by-line, rewriting the top-level
    /// `sessionId` of every JSON line to `newSessionID`, writing to
    /// `<newSessionID>.jsonl` beside the parent. Truncation:
    /// - `.turn` checkpoints stop STRICTLY BEFORE the anchor line (fallback:
    ///   before the `turnIndex`-th user-prompt line when the uuid is absent).
    /// - `.manual` checkpoints copy THROUGH the anchor inclusive (fallback:
    ///   to end of file).
    /// Returns the new session file URL. Cleans up the partial file on error.
    nonisolated static func forkClaudeTranscript(
        parentFileURL: URL,
        checkpoint: VaultSessionCheckpoint,
        newSessionID: String,
        fileManager: FileManager = .default,
        maxBytes: Int = maxForkBytes
    ) throws -> URL {
        // The id lands in a file name; only current caller mints UUIDs, but a
        // future caller must not be able to escape the parent directory.
        guard !newSessionID.isEmpty,
              !newSessionID.contains("/"),
              !newSessionID.contains(".."),
              newSessionID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw VaultCheckpointForkError.invalidSessionID
        }
        guard fileManager.fileExists(atPath: parentFileURL.path),
              let reader = try? FileHandle(forReadingFrom: parentFileURL) else {
            throw VaultCheckpointForkError.parentMissing
        }
        defer { try? reader.close() }

        let destinationURL = parentFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(newSessionID + ".jsonl")
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: destinationURL) else {
            throw VaultCheckpointForkError.writeFailed
        }

        var succeeded = false
        defer {
            try? writer.close()
            if !succeeded {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        var buffer = Data()
        var bytesRead = 0
        var wroteAnyLine = false
        var sawAnchor = false
        var userLineIndex = 0
        let chunkSize = 256 * 1024

        func handle(line: Data) throws -> Bool {
            // Returns true to stop streaming (anchor reached).
            guard !line.isEmpty else { return false }
            let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            let lineUUID = parsed?["uuid"] as? String
            let isUserPrompt = parsed.map { VaultSessionCheckpoints.userPromptText(from: $0) != nil } ?? false
            if isUserPrompt { userLineIndex += 1 }

            let isAnchor: Bool
            if let anchorUUID = checkpoint.anchorLineUUID {
                isAnchor = lineUUID == anchorUUID
            } else if checkpoint.source == .turn {
                isAnchor = isUserPrompt && userLineIndex == checkpoint.turnIndex
            } else {
                isAnchor = false
            }

            switch checkpoint.source {
            case .turn:
                // Stop BEFORE the anchor: the fork replays state from before
                // that prompt ran.
                if isAnchor {
                    sawAnchor = true
                    return true
                }
            case .manual:
                break
            }

            try write(line: line, parsed: parsed, newSessionID: newSessionID, to: writer)
            wroteAnyLine = true

            if checkpoint.source == .manual, isAnchor {
                sawAnchor = true
                return true
            }
            return false
        }

        var finished = false
        while !finished {
            let chunk: Data
            do {
                // A read error must fail the fork, not masquerade as EOF —
                // otherwise a manual fork silently drops the tail.
                guard let read = try reader.read(upToCount: chunkSize) else { break }
                chunk = read
            } catch {
                throw VaultCheckpointForkError.readFailed
            }
            guard !chunk.isEmpty else { break }
            bytesRead += chunk.count
            if bytesRead > maxBytes {
                throw VaultCheckpointForkError.byteCapExceeded
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: newlineByte) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if try handle(line: line) {
                    finished = true
                    break
                }
            }
        }
        if !finished, !buffer.isEmpty {
            _ = try handle(line: buffer)
        }

        // A turn anchor that never appeared means the checkpoint points at a
        // different (or rewritten) file — refuse rather than fork the whole
        // transcript under a "before the prompt" label.
        if checkpoint.source == .turn, checkpoint.anchorLineUUID != nil, !sawAnchor {
            throw VaultCheckpointForkError.anchorNotFound
        }
        guard wroteAnyLine else {
            throw VaultCheckpointForkError.emptyFork
        }

        succeeded = true
        return destinationURL
    }

    nonisolated private static func write(
        line: Data,
        parsed: [String: Any]?,
        newSessionID: String,
        to writer: FileHandle
    ) throws {
        let output: Data
        if var obj = parsed, obj["sessionId"] is String {
            obj["sessionId"] = newSessionID
            // JSONSerialization round-trip preserves content; key order may
            // change, which Claude's JSONL reader does not care about.
            guard let encoded = try? JSONSerialization.data(withJSONObject: obj) else {
                throw VaultCheckpointForkError.writeFailed
            }
            output = encoded
        } else {
            // Lines without a top-level sessionId (or non-JSON lines) copy
            // through verbatim.
            output = line
        }
        do {
            try writer.write(contentsOf: output)
            try writer.write(contentsOf: Data([newlineByte]))
        } catch {
            throw VaultCheckpointForkError.writeFailed
        }
    }
}

extension SessionEntry {
    /// Vault record for a just-forked Claude transcript. Keeps the PARENT's
    /// cwd (issue #5941: forking into a different cwd fails) and specifics;
    /// the identity is the freshly minted session id + file.
    func forkedClaudeEntry(newSessionID: String, fileURL: URL, now: Date) -> SessionEntry {
        let format = String(
            localized: "sessionIndex.checkpoints.forkTitle",
            defaultValue: "%@ (fork)"
        )
        return SessionEntry(
            id: "claude:" + fileURL.path,
            agent: agent,
            sessionId: newSessionID,
            title: String(format: format, displayTitle),
            cwd: cwd,
            gitBranch: gitBranch,
            pullRequest: nil,
            modified: now,
            fileURL: fileURL,
            specifics: specifics,
            created: now,
            messageCount: nil
        )
    }
}
