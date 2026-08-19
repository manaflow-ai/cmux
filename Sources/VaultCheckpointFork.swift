import Foundation

enum VaultCheckpointForkError: Error, Equatable {
    case parentMissing
    case invalidSessionID
    case anchorNotFound
    case emptyFork
    case byteCapExceeded
    case readFailed
    case writeFailed
    case unsupportedHarness

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
        case .unsupportedHarness:
            return String(localized: "sessionIndex.checkpoints.error.unsupportedHarness",
                          defaultValue: "Fork from checkpoint isn't available for this agent yet")
        }
    }
}

/// One harness-parameterized fork copy: which file streams, where the copy
/// lands, how a line's anchor token is computed (must agree with the
/// derivation), which lines count as user prompts (turn-index fallback), and
/// how a line is rewritten for the new session identity.
struct VaultForkPlan {
    let parentFileURL: URL
    let destinationFileURL: URL
    /// Must produce the same tokens the harness's derivation produced.
    let anchorToken: ([String: Any], Int) -> String?
    let userPrompt: ([String: Any]) -> String?
    /// Returns a mutated line object to re-serialize, or nil to copy the raw
    /// line bytes verbatim.
    let rewriteLine: ([String: Any]) -> [String: Any]?
}

/// Streams a parent transcript into a new session file, truncated at a
/// checkpoint. The parent is never touched; divergence happens entirely in
/// the new session (issue #10156 class: identity is the minted id — never
/// inferred from process state).
enum VaultCheckpointForker {
    /// Hard cap on how much parent transcript a fork may stream.
    nonisolated static let maxForkBytes = 64 * 1024 * 1024
    private static let newlineByte: UInt8 = 0x0a

    /// Truncation rules:
    /// - `.turn` checkpoints stop STRICTLY BEFORE the anchor line (fallback:
    ///   before the `turnIndex`-th user-prompt line when the anchor is absent).
    /// - `.manual` checkpoints copy THROUGH the anchor inclusive (fallback:
    ///   to end of file).
    /// Returns the new session file URL. Cleans up the partial file on error.
    nonisolated static func fork(
        plan: VaultForkPlan,
        checkpoint: VaultSessionCheckpoint,
        fileManager: FileManager = .default,
        maxBytes: Int = maxForkBytes
    ) throws -> URL {
        guard fileManager.fileExists(atPath: plan.parentFileURL.path),
              let reader = try? FileHandle(forReadingFrom: plan.parentFileURL) else {
            throw VaultCheckpointForkError.parentMissing
        }
        defer { try? reader.close() }

        let destinationURL = plan.destinationFileURL
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
        var lineIndex = -1
        let chunkSize = 256 * 1024

        func handle(line: Data) throws -> Bool {
            // Returns true to stop streaming (anchor reached).
            guard !line.isEmpty else { return false }
            let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            lineIndex += 1
            let lineAnchor = parsed.flatMap { plan.anchorToken($0, lineIndex) }
            let isUserPrompt = parsed.map { plan.userPrompt($0) != nil } ?? false
            if isUserPrompt { userLineIndex += 1 }

            let isAnchor: Bool
            if let anchor = checkpoint.anchor {
                isAnchor = lineAnchor == anchor
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

            try write(line: line, parsed: parsed, plan: plan, to: writer)
            wroteAnyLine = true

            if checkpoint.source == .manual, isAnchor {
                sawAnchor = true
                return true
            }
            return false
        }

        var finished = false
        while !finished {
            // Reads are bounded by the remaining budget so a transcript whose
            // anchor sits inside the cap forks even when the file is larger,
            // and the cap trips before any truncated data could be processed.
            let remaining = maxBytes - bytesRead
            if remaining <= 0 {
                // A file that ends exactly at the cap is fully read, not a
                // violation — only unread data past the cap is.
                let probe: Data?
                do {
                    probe = try reader.read(upToCount: 1)
                } catch {
                    throw VaultCheckpointForkError.readFailed
                }
                if probe?.isEmpty ?? true { break }
                throw VaultCheckpointForkError.byteCapExceeded
            }
            let chunk: Data
            do {
                // A read error must fail the fork, not masquerade as EOF —
                // otherwise a manual fork silently drops the tail.
                guard let read = try reader.read(upToCount: min(chunkSize, remaining)) else { break }
                chunk = read
            } catch {
                throw VaultCheckpointForkError.readFailed
            }
            guard !chunk.isEmpty else { break }
            bytesRead += chunk.count
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

        // An anchor that never appeared means the checkpoint points at a
        // different (or rewritten) file — refuse rather than mislabel the
        // copy: a turn fork would include the anchored prompt's turn, and a
        // manual fork would silently include every turn added AFTER the
        // checkpoint was taken. Only anchor-less manual checkpoints copy to
        // end of file by design.
        if checkpoint.anchor != nil, !sawAnchor {
            throw VaultCheckpointForkError.anchorNotFound
        }
        guard wroteAnyLine else {
            throw VaultCheckpointForkError.emptyFork
        }

        succeeded = true
        return destinationURL
    }

    /// The id lands in file names; callers mint UUIDs, but a future caller
    /// must not be able to escape the parent directory.
    nonisolated static func validateSessionID(_ newSessionID: String) throws {
        guard !newSessionID.isEmpty,
              !newSessionID.contains("/"),
              !newSessionID.contains(".."),
              newSessionID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw VaultCheckpointForkError.invalidSessionID
        }
    }

    nonisolated private static func write(
        line: Data,
        parsed: [String: Any]?,
        plan: VaultForkPlan,
        to writer: FileHandle
    ) throws {
        let output: Data
        if let parsed, let rewritten = plan.rewriteLine(parsed) {
            // JSONSerialization round-trip preserves content; key order may
            // change, which the JSONL readers do not care about.
            guard let encoded = try? JSONSerialization.data(withJSONObject: rewritten) else {
                throw VaultCheckpointForkError.writeFailed
            }
            output = encoded
        } else {
            // Lines without identity fields (or non-JSON lines) copy through
            // verbatim.
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
    /// Vault record for a just-forked session. Keeps the PARENT's cwd (issue
    /// #5941: forking into a different cwd fails) and specifics; the identity
    /// is the freshly minted session id + file.
    func forkedEntry(newSessionID: String, fileURL: URL, now: Date) -> SessionEntry {
        let format = String(
            localized: "sessionIndex.checkpoints.forkTitle",
            defaultValue: "%@ (fork)"
        )
        return SessionEntry(
            id: agent.rawValue + ":" + fileURL.path,
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
