public import Foundation

/// Tracks whether an SSH PTY attachment delivered output newer than its
/// initial scrollback replay.
public struct SSHPTYAttachOutputProgress: Sendable {
    private static let maximumValidatedReplayPrefixBytes = 1 << 20
    private static let maximumBufferedReplayBytes = 1 << 20
    private static let fingerprintOffset: UInt64 = 14695981039346656037
    private static let fingerprintPrime: UInt64 = 1099511628211

    /// Initial replay bytes that have not yet arrived from the bridge.
    public private(set) var replayBytesRemaining: Int

    private var replayBytesToSuppressRemaining: Int
    private let expectedReplayFingerprint: UInt64?
    private let replayPrefixTargetLength: Int
    private var replayPrefixCandidate = Data()
    private var replayPrefixValidationComplete: Bool
    private var bufferingValidatedReplay = false
    private var validatedReplayOutput = Data()
    private var replayFingerprintHash = Self.fingerprintOffset

    /// Whether any output arrived after the initial replay boundary.
    public private(set) var receivedLiveOutput = false

    /// Fingerprint of the complete replay once the bridge delivered it.
    public private(set) var completedReplayFingerprint: UInt64?

    /// Creates progress accounting for an attachment's declared replay size.
    ///
    /// - Parameters:
    ///   - replayBytes: Bytes the bridge will send before live output.
    ///   - suppressReplayBytes: Previously delivered replay prefix bytes to
    ///     hide on a managed reattach. `nil` preserves the legacy behavior of
    ///     suppressing the complete declared replay when requested.
    ///   - expectedReplayFingerprint: Fingerprint of the previously delivered
    ///     prefix. When supplied, the prefix is buffered until its identity is
    ///     confirmed; a bounded-scrollback rollover forwards the replacement
    ///     snapshot instead of dropping it.
    public init(
        replayBytes: Int,
        suppressReplayBytes: Int? = nil,
        expectedReplayFingerprint: UInt64? = nil
    ) {
        let normalizedReplayBytes = max(0, replayBytes)
        let normalizedSuppressBytes = min(
            normalizedReplayBytes,
            max(0, suppressReplayBytes ?? normalizedReplayBytes)
        )
        let canValidatePrefix = expectedReplayFingerprint != nil &&
            normalizedSuppressBytes <= Self.maximumValidatedReplayPrefixBytes
        replayBytesRemaining = normalizedReplayBytes
        replayBytesToSuppressRemaining = canValidatePrefix || expectedReplayFingerprint == nil
            ? normalizedSuppressBytes
            : 0
        self.expectedReplayFingerprint = expectedReplayFingerprint
        replayPrefixTargetLength = canValidatePrefix ? normalizedSuppressBytes : 0
        replayPrefixValidationComplete = !canValidatePrefix || normalizedSuppressBytes == 0
        bufferingValidatedReplay = canValidatePrefix
    }

    /// Computes the stable fingerprint used to validate a replay prefix.
    public static func fingerprint(of data: Data) -> UInt64 {
        var hash = fingerprintOffset
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= fingerprintPrime
        }
        return hash
    }

    /// Records one ordered output chunk from the bridge.
    public mutating func recordOutput(byteCount: Int) {
        guard byteCount > 0 else { return }
        let replayBytes = min(byteCount, replayBytesRemaining)
        replayBytesRemaining -= replayBytes
        if byteCount > replayBytes {
            receivedLiveOutput = true
        }
    }

    /// Returns the portion of one bridge chunk that belongs in the terminal.
    ///
    /// A managed reconnect may receive the same initial scrollback snapshot on
    /// every attach. The wrapper already rendered the previously delivered
    /// prefix on its first attempt, so later attempts can discard only that
    /// prefix while forwarding output appended during the detached interval.
    ///
    /// - Parameters:
    ///   - data: Ordered bytes read from the bridge.
    ///   - suppressingReplay: Whether the current managed attempt should hide
    ///     its declared initial replay.
    /// - Returns: Bytes that should be forwarded to the terminal.
    public mutating func terminalOutput(
        from data: Data,
        suppressingReplay: Bool
    ) -> Data {
        guard !data.isEmpty else { return Data() }
        let replayChunkBytes = min(data.count, replayBytesRemaining)
        if replayChunkBytes > 0 {
            updateReplayFingerprint(Data(data.prefix(replayChunkBytes)))
        }
        recordOutput(byteCount: data.count)

        if replayBytesRemaining == 0, completedReplayFingerprint == nil {
            completedReplayFingerprint = replayFingerprintHash
        }

        if suppressingReplay,
           expectedReplayFingerprint != nil,
           !replayPrefixValidationComplete {
            let candidateBytesRemaining = replayPrefixTargetLength - replayPrefixCandidate.count
            let candidateBytes = min(candidateBytesRemaining, data.count)
            replayPrefixCandidate.append(data.prefix(candidateBytes))
            guard replayPrefixCandidate.count == replayPrefixTargetLength else {
                return Data()
            }
            replayPrefixValidationComplete = true
            let matches = Self.fingerprint(of: replayPrefixCandidate) == expectedReplayFingerprint
            let candidate = replayPrefixCandidate
            replayPrefixCandidate.removeAll(keepingCapacity: false)
            replayBytesToSuppressRemaining = 0
            if !matches {
                // The bounded snapshot rolled over (or the session was
                // replaced), so none of the new snapshot can be proven
                // duplicate.
                validatedReplayOutput = candidate
                receivedLiveOutput = true
            }
            let replayRemainder = Data(
                data.dropFirst(candidateBytes)
                    .prefix(max(0, replayChunkBytes - candidateBytes))
            )
            appendValidatedReplayBytes(replayRemainder)
            if !replayRemainder.isEmpty {
                receivedLiveOutput = true
            }
            return flushValidatedReplayIfComplete(from: data, replayChunkBytes: replayChunkBytes)
        }

        if suppressingReplay,
           expectedReplayFingerprint != nil,
           bufferingValidatedReplay {
            appendValidatedReplayBytes(Data(data.prefix(replayChunkBytes)))
            if replayChunkBytes > 0 {
                receivedLiveOutput = true
            }
            return flushValidatedReplayIfComplete(
                from: data,
                replayChunkBytes: replayChunkBytes
            )
        }

        let suppressBytes = suppressingReplay
            ? min(data.count, replayBytesToSuppressRemaining)
            : 0
        if suppressingReplay {
            replayBytesToSuppressRemaining -= suppressBytes
            // A partially suppressed replay contains a suffix that was
            // produced after the previous attach. It is live from the pane's
            // perspective even though the daemon labels the whole snapshot
            // as replay.
            if suppressBytes < replayChunkBytes {
                receivedLiveOutput = true
            }
            if expectedReplayFingerprint != nil,
               replayBytesToSuppressRemaining == 0,
               replayBytesRemaining > 0 {
                receivedLiveOutput = true
            }
        }
        guard suppressingReplay, suppressBytes > 0 else { return data }
        return Data(data.dropFirst(suppressBytes))
    }

    /// Finishes a buffered candidate when the bridge closes before replay ends.
    ///
    /// - Parameter discarding: When another managed attempt is guaranteed, drop
    ///   the unvalidated candidate so the next full snapshot cannot duplicate
    ///   bytes that were already rendered by this attempt.
    public mutating func finishPendingReplay(discarding: Bool = false) -> Data {
        guard !replayPrefixValidationComplete || bufferingValidatedReplay else { return Data() }
        replayPrefixValidationComplete = true
        replayBytesToSuppressRemaining = 0
        let pending = replayPrefixCandidate + validatedReplayOutput
        replayPrefixCandidate.removeAll(keepingCapacity: false)
        validatedReplayOutput.removeAll(keepingCapacity: false)
        bufferingValidatedReplay = false
        if discarding {
            return Data()
        }
        receivedLiveOutput = true
        return pending
    }

    private mutating func updateReplayFingerprint(_ data: Data) {
        for byte in data {
            replayFingerprintHash ^= UInt64(byte)
            replayFingerprintHash &*= Self.fingerprintPrime
        }
    }

    private mutating func appendValidatedReplayBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        guard validatedReplayOutput.count <= Self.maximumBufferedReplayBytes - data.count else {
            // The daemon's replay is bounded to the same order of magnitude;
            // if an older peer violates that contract, stop buffering rather
            // than allowing reconnect validation to grow without bound.
            bufferingValidatedReplay = false
            return
        }
        validatedReplayOutput.append(data)
    }

    private mutating func flushValidatedReplayIfComplete(
        from data: Data,
        replayChunkBytes: Int
    ) -> Data {
        guard replayBytesRemaining == 0 else { return Data() }
        let liveRemainder = Data(data.dropFirst(replayChunkBytes))
        let output = validatedReplayOutput + liveRemainder
        validatedReplayOutput.removeAll(keepingCapacity: false)
        bufferingValidatedReplay = false
        if !output.isEmpty {
            receivedLiveOutput = true
        }
        return output
    }
}
