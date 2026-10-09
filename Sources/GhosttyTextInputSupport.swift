import AppKit

/// Returns true for Unicode scalars that represent terminal control input rather
/// than printable text.
nonisolated func isControlCharacterScalar(_ scalar: UnicodeScalar) -> Bool {
    scalar.value < 0x20 || scalar.value == 0x7F
}

/// Filters AppKit text fallback payloads down to printable text that should be
/// forwarded as Ghostty key text.
nonisolated func shouldSendText(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    if text.count == 1, let scalar = text.unicodeScalars.first {
        return !isControlCharacterScalar(scalar)
    }
    return true
}

/// Tracks raw numpad fallback sends that may be followed by a deferred IME
/// commit for the same key. Each record is consumed once so rapid numpad input
/// does not overwrite older in-flight commits.
///
/// AppKit does not expose a stable correlation token that ties an async
/// `insertText` callback back to the originating `keyDown`, so this type keeps
/// the fallback state narrowly scoped: plain numeric-pad fallback text, input
/// method sources only, one-shot matching, and a short expiry window. If a
/// future input pipeline can provide structural key/commit correlation, replace
/// this timing heuristic with that source of truth.
struct NumpadIMECommitDeduplicator {
    /// 250 ms covers observed AppKit deferred IME commits while keeping the
    /// suppression window short enough that unrelated text injection ages out.
    private static let commitSuppressionWindow: TimeInterval = 0.25
    private static let maxPendingCommits = 8

    private struct PendingCommit {
        let text: String
        let keyCode: UInt16
        let sourceId: String?
        let timestamp: TimeInterval
    }

    private var pendingCommits: [PendingCommit] = []

    /// Records a Ghostty-accepted raw numpad fallback that is eligible to absorb
    /// the matching deferred IME commit.
    mutating func recordFallback(text: String, event: NSEvent, sourceId: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredCommits(now: now)

        let flags = normalizedNumpadFlags(event.modifierFlags)
        // Plain key layouts do not emit deferred IME commits; keep this state
        // owned by input-method fallback sends instead of every numpad digit.
        guard flags == [.numericPad],
              isDeferredCommitInputSource(sourceId),
              text.allSatisfy(\.isNumber) else {
            return
        }

        pendingCommits.append(PendingCommit(
            text: text,
            keyCode: event.keyCode,
            sourceId: sourceId,
            timestamp: now
        ))
        if pendingCommits.count > Self.maxPendingCommits {
            pendingCommits.removeFirst(pendingCommits.count - Self.maxPendingCommits)
        }
    }

    /// Returns true when an AppKit IME commit matches a pending raw numpad
    /// fallback and should be consumed instead of sent to Ghostty again.
    mutating func shouldSuppressCommit(
        _ text: String,
        currentEvent: NSEvent?,
        sourceId: String?,
        externalCommittedTextDepth: Int,
        keyTextAccumulatorIsActive: Bool
    ) -> Bool {
        if externalCommittedTextDepth > 0 {
            pendingCommits.removeAll()
            return false
        }

        guard !keyTextAccumulatorIsActive else {
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredCommits(now: now)

        guard !pendingCommits.isEmpty else {
            return false
        }

        guard let index = pendingCommits.firstIndex(where: { pendingCommit in
            pendingCommit.text == text && pendingCommit.sourceId == sourceId
        }) else {
            return false
        }

        let pendingCommit = pendingCommits[index]
        if let currentEvent, currentEvent.type == .keyDown {
            let currentFlags = normalizedNumpadFlags(currentEvent.modifierFlags)
            guard currentFlags == [.numericPad], currentEvent.keyCode == pendingCommit.keyCode else {
                pendingCommits.remove(at: index)
                return false
            }
        }

        pendingCommits.remove(at: index)
        return true
    }

    private mutating func pruneExpiredCommits(now: TimeInterval) {
        pendingCommits.removeAll { now - $0.timestamp > Self.commitSuppressionWindow }
    }

    private func isDeferredCommitInputSource(_ sourceId: String?) -> Bool {
        guard let sourceId else { return false }
        return sourceId.localizedCaseInsensitiveContains("inputmethod")
    }

    private func normalizedNumpadFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .capsLock])
    }
}

extension GhosttyNSView {
    func notePotentialDeferredNumpadIMECommit(text: String, event: NSEvent) {
        numpadIMECommitDeduplicator.recordFallback(
            text: text,
            event: event,
            sourceId: KeyboardLayout.id
        )
    }

    func shouldSuppressDeferredNumpadIMECommit(_ text: String) -> Bool {
        numpadIMECommitDeduplicator.shouldSuppressCommit(
            text,
            currentEvent: NSApp.currentEvent,
            sourceId: KeyboardLayout.id,
            externalCommittedTextDepth: externalCommittedTextDepth,
            keyTextAccumulatorIsActive: keyTextAccumulator != nil
        )
    }
}
