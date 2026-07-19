public import Foundation

/// Detects completed interactive turns from a raw PTY output stream.
///
/// The detector becomes ready after seeing the configured prompt on a logical
/// line. It then requires a non-empty echoed submission and subsequent
/// output before a later prompt can complete a turn. Exact prompt text first
/// becomes a pending boundary; callers confirm it after the configured debounce
/// interval or let subsequent same-line output invalidate it. ANSI CSI and OSC
/// sequences are ignored, while carriage returns and backspaces update the line.
///
/// Prompt text is the only idle signal third-party REPLs expose, so a model
/// that streams the exact prompt bytes and stalls past the debounce is
/// indistinguishable from idleness by design; callers bound the blast radius
/// with process verification and delivery deduplication.
///
/// The detector is designed for Ghostty's synchronous PTY read callback: once
/// the current line can no longer influence detection, whole printable runs
/// are skipped without per-byte state machine work, so surfaces that never
/// show an agent prompt pay roughly one state transition per line.
public struct PromptLineTurnDetector: Sendable {
    private enum StablePhase: Sendable {
        case seekingInitialPrompt
        case readyForSubmission
        case awaitingPrompt(observedOutput: Bool)
    }

    private enum Phase: Sendable {
        case stable(StablePhase)
        case pendingPrompt(previous: StablePhase)
    }

    private enum ControlSequence: Sendable {
        case none
        case escape
        case csi
        case osc
        case oscEscape
    }

    private static let maximumLogicalLineBytes = 4_096
    private static let maximumCSIParameterBytes = 12

    private let configuration: PromptLineTurnDetectionConfiguration
    private let maximumWaitingPromptLineByteCount: Int
    private let promptVisibleByteCount: Int
    private var phase: Phase = .stable(.seekingInitialPrompt)
    private var controlSequence: ControlSequence = .none
    /// CSI parameter/intermediate bytes of the sequence being parsed, so the
    /// terminator can distinguish line-rewriting controls (CSI 2K, CSI 1G)
    /// from inert ones (SGR, cursor shifts). Overlong sequences are treated
    /// as inert rather than growing the buffer.
    private var csiParameterBytes: [UInt8] = []
    private var csiParameterOverflowed = false
    private var logicalLine: [UInt8] = []
    private var logicalLineOverflowed = false
    /// Visible bytes currently in `logicalLine`, maintained incrementally so
    /// per-byte evaluation stays O(1) on the PTY read thread.
    private var visibleByteCount = 0
    /// Printable bytes skipped after the line stopped mattering. They still
    /// count toward the logical line so backspace editing stays exact: while
    /// this is nonzero, backspaces consume skipped bytes before the stored
    /// (frozen, already disqualified) prefix.
    private var unstoredLineByteCount = 0
    /// Snapshots taken when a logical line outgrows the storage cap, so an
    /// oversized pasted submission or response line keeps its turn semantics.
    private var overflowedLineStartedWithPrompt = false
    private var overflowedSubmissionHadVisibleContent = false
    private var overflowedLineHadVisibleContent = false
    private var nextConfirmationIdentifier: UInt64 = 0

    /// Increments when an echoed submission starts a new turn.
    ///
    /// Callers can compare this value after each consumed chunk to bind the
    /// turn to the process that received the submission.
    public private(set) var submissionCount: UInt64 = 0

    /// The current prompt boundary awaiting debounce confirmation, if any.
    public private(set) var pendingConfirmation: PromptLineTurnConfirmation?

    /// Changes whenever the pending confirmation is created or invalidated.
    ///
    /// A caller can cheaply compare this value after each PTY chunk and only
    /// schedule asynchronous work when the confirmation state changed.
    public private(set) var confirmationRevision: UInt64 = 0

    /// Creates a detector for one prompt-line configuration.
    ///
    /// - Parameter configuration: The exact prompt that brackets interactive turns.
    public init(configuration: PromptLineTurnDetectionConfiguration) {
        self.configuration = configuration
        self.maximumWaitingPromptLineByteCount =
            configuration.waitingPromptLineBytes.map(\.count).max() ?? 0
        self.promptVisibleByteCount = configuration.promptBytes
            .reduce(into: 0) { count, byte in
                if Self.isVisibleContentByte(byte) { count += 1 }
            }
        logicalLine.reserveCapacity(configuration.promptBytes.count + 64)
    }

    /// Consumes one PTY output chunk.
    ///
    /// Inspect ``pendingConfirmation`` and ``confirmationRevision`` after this
    /// call. A completion is never emitted until ``confirm(_:)`` succeeds.
    ///
    /// - Parameter data: Raw bytes read from the PTY.
    public mutating func consume(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            consume(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Consumes one borrowed PTY output chunk.
    ///
    /// - Parameter bytes: Raw bytes read from the PTY.
    public mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte >= 0x20, byte != 0x7F,
               controlSequence == .none,
               printableBytesCannotChangeState {
                // Skip the rest of the printable run without state machine
                // work; only control bytes below can change detection state.
                var cursor = index + 1
                while cursor < bytes.endIndex {
                    let next = bytes[cursor]
                    if next < 0x20 || next == 0x7F { break }
                    cursor += 1
                }
                unstoredLineByteCount += cursor - index
                index = cursor
                continue
            }
            consume(byte)
            index += 1
        }
    }

    /// Confirms a prompt boundary after its debounce interval elapsed.
    ///
    /// Stale confirmations return zero, including candidates invalidated by
    /// later visible bytes on the same logical line.
    ///
    /// - Parameter confirmation: The candidate previously read from
    ///   ``pendingConfirmation``.
    /// - Returns: One for a completed model turn, or zero for an invalidated
    ///   or already-confirmed candidate.
    public mutating func confirm(_ confirmation: PromptLineTurnConfirmation) -> Int {
        guard pendingConfirmation?.identifier == confirmation.identifier,
              case .pendingPrompt = phase else {
            return 0
        }

        let completedTurns = confirmation.completedTurnCount
        phase = .stable(.readyForSubmission)
        setPendingConfirmation(nil)
        return completedTurns
    }

    /// Whether appending printable bytes to the current line can still change
    /// any observable detector state. When false, whole printable runs are
    /// skipped, which keeps the PTY read callback near memcpy cost on
    /// surfaces that never show the agent prompt.
    private var printableBytesCannotChangeState: Bool {
        guard case .stable(let stablePhase) = phase else {
            // A pending prompt is invalidated by the next visible byte.
            return false
        }
        guard lineCannotBecomeWaitingPrompt else { return false }
        switch stablePhase {
        case .seekingInitialPrompt:
            // Line content is only compared against prompt patterns here,
            // and this line is already disqualified.
            return true
        case .awaitingPrompt(let observedOutput):
            // Before output is observed, the next visible byte flips the
            // flag; afterwards printable bytes are inert.
            return observedOutput
        case .readyForSubmission:
            // Printable bytes matter until the line's submission shape is
            // decided: either it diverged from the prompt prefix entirely,
            // or it already carries visible submission content.
            if logicalLineOverflowed {
                return !overflowedLineStartedWithPrompt || overflowedSubmissionHadVisibleContent
            }
            if logicalLine.starts(with: configuration.promptBytes) {
                return visibleByteCount > promptVisibleByteCount
            }
            // Disqualified as a prompt prefix and diverged from the prompt:
            // this line can never become an echoed submission.
            return true
        }
    }

    private var lineCannotBecomeWaitingPrompt: Bool {
        if logicalLineOverflowed || unstoredLineByteCount > 0 { return true }
        if logicalLine.count > maximumWaitingPromptLineByteCount { return true }
        return !configuration.waitingPromptLineBytes.contains { $0.starts(with: logicalLine) }
    }

    private mutating func consume(_ byte: UInt8) {
        switch controlSequence {
        case .escape:
            switch byte {
            case UInt8(ascii: "["): controlSequence = .csi
            case UInt8(ascii: "]"): controlSequence = .osc
            default: controlSequence = .none
            }
            return
        case .csi:
            if (0x40...0x7E).contains(byte) {
                controlSequence = .none
                handleCSITerminator(byte)
            } else if csiParameterBytes.count < Self.maximumCSIParameterBytes {
                csiParameterBytes.append(byte)
            } else {
                csiParameterOverflowed = true
            }
            return
        case .osc:
            if byte == 0x07 {
                controlSequence = .none
            } else if byte == 0x1B {
                controlSequence = .oscEscape
            }
            return
        case .oscEscape:
            controlSequence = byte == UInt8(ascii: "\\") ? .none : .osc
            return
        case .none:
            break
        }

        switch byte {
        case 0x1B:
            controlSequence = .escape
            csiParameterBytes.removeAll(keepingCapacity: true)
            csiParameterOverflowed = false
        case 0x0A, 0x0D:
            invalidatePendingPrompt()
            handleLineBoundary()
            resetLogicalLine()
        case 0x08, 0x7F:
            invalidatePendingPrompt()
            if logicalLineOverflowed {
                // Erasing from an overflowed line makes its exact content
                // unknowable; fail closed on the latched submission snapshot
                // so an erased oversized paste cannot count a submission at
                // the boundary. Output-ness stays latched: the erased bytes
                // were still visible output for turn observation.
                overflowedSubmissionHadVisibleContent = false
            }
            if unstoredLineByteCount > 0 {
                unstoredLineByteCount -= 1
            } else if !logicalLineOverflowed, let removed = logicalLine.popLast() {
                if Self.isVisibleContentByte(removed) {
                    visibleByteCount -= 1
                }
            }
            evaluateLogicalLine()
        case 0x20...0x7E, 0x80...0xFF:
            if pendingConfirmation != nil {
                invalidatePendingPrompt()
            }
            appendToLogicalLine(byte)
            evaluateLogicalLine()
        default:
            break
        }
    }

    private mutating func appendToLogicalLine(_ byte: UInt8) {
        guard !logicalLineOverflowed else {
            if Self.isVisibleContentByte(byte) {
                overflowedLineHadVisibleContent = true
                if overflowedLineStartedWithPrompt {
                    overflowedSubmissionHadVisibleContent = true
                }
            }
            return
        }
        guard logicalLine.count < Self.maximumLogicalLineBytes else {
            overflowedLineStartedWithPrompt = logicalLine.starts(with: configuration.promptBytes)
            overflowedSubmissionHadVisibleContent = overflowedLineStartedWithPrompt &&
                containsVisibleContent(logicalLine.dropFirst(configuration.promptBytes.count))
            overflowedLineHadVisibleContent = visibleByteCount > 0 ||
                Self.isVisibleContentByte(byte)
            logicalLine.removeAll(keepingCapacity: true)
            visibleByteCount = 0
            logicalLineOverflowed = true
            markOutputObserved()
            return
        }
        logicalLine.append(byte)
        if Self.isVisibleContentByte(byte) {
            visibleByteCount += 1
        }
    }

    private mutating func evaluateLogicalLine() {
        // Fast paths: a line with skipped or overflowed bytes, or one longer
        // than every waiting-prompt pattern, can neither equal nor prefix a
        // prompt, so only output observation remains. Together with the
        // incremental visible-byte count this keeps per-byte cost constant
        // on the PTY read thread.
        if unstoredLineByteCount > 0 || logicalLineOverflowed {
            if currentLineHasVisibleContent {
                markOutputObserved()
            }
            return
        }
        if logicalLine.count > maximumWaitingPromptLineByteCount {
            if visibleByteCount > 0 {
                markOutputObserved()
            }
            return
        }
        guard configuration.waitingPromptLineBytes.contains(logicalLine),
              case .stable(let stablePhase) = phase else {
            if !configuration.waitingPromptLineBytes.contains(where: { $0.starts(with: logicalLine) }),
               visibleByteCount > 0 {
                markOutputObserved()
            }
            return
        }

        switch stablePhase {
        case .seekingInitialPrompt, .readyForSubmission:
            phase = .stable(.readyForSubmission)
            return
        case .awaitingPrompt(let observedOutput):
            guard observedOutput else {
                phase = .stable(.readyForSubmission)
                return
            }
        }
        phase = .pendingPrompt(previous: stablePhase)
        nextConfirmationIdentifier &+= 1
        setPendingConfirmation(PromptLineTurnConfirmation(
            identifier: nextConfirmationIdentifier,
            completedTurnCount: 1,
            delay: configuration.confirmationDelay
        ))
    }

    /// Handles a completed CSI sequence. REPL readline implementations
    /// (Ollama's liner among them) redraw their prompt line in place with
    /// "cursor to column 1" (CSI G / CSI 1G) and "erase entire line"
    /// (CSI 2K) instead of CR/LF — a model-load spinner emits dozens of such
    /// frames. Both rewrite the visible line from its start, so the logical
    /// line resets exactly as it does for a carriage return, minus the
    /// submission boundary: an erased or overwritten line was never
    /// submitted. Erase-to-right (bare CSI K) is not a full-line rewrite and
    /// stays inert because the detector does not track cursor columns.
    private mutating func handleCSITerminator(_ terminator: UInt8) {
        defer {
            csiParameterBytes.removeAll(keepingCapacity: true)
            csiParameterOverflowed = false
        }
        guard !csiParameterOverflowed else { return }
        switch terminator {
        case UInt8(ascii: "G"):
            guard csiParameterBytes.isEmpty ||
                csiParameterBytes == [UInt8(ascii: "1")] ||
                csiParameterBytes == [UInt8(ascii: "0")] else {
                return
            }
            invalidatePendingPrompt()
            resetLogicalLine()
        case UInt8(ascii: "K"):
            guard csiParameterBytes == [UInt8(ascii: "2")] else { return }
            invalidatePendingPrompt()
            resetLogicalLine()
        default:
            break
        }
    }

    private mutating func invalidatePendingPrompt() {
        guard case .pendingPrompt(let previous) = phase else { return }
        phase = .stable(previous)
        setPendingConfirmation(nil)
    }

    private mutating func handleLineBoundary() {
        guard case .stable(let stablePhase) = phase else { return }
        switch stablePhase {
        case .readyForSubmission:
            if logicalLineOverflowed {
                // A pasted submission longer than the storage cap still
                // starts a turn when it began with the prompt and carried
                // visible content after it.
                if overflowedLineStartedWithPrompt, overflowedSubmissionHadVisibleContent {
                    phase = .stable(.awaitingPrompt(observedOutput: false))
                    submissionCount &+= 1
                }
                return
            }
            guard logicalLine.starts(with: configuration.promptBytes),
                  !configuration.waitingPromptLineBytes.contains(logicalLine) else {
                return
            }
            let submission = logicalLine.dropFirst(configuration.promptBytes.count)
            if containsVisibleContent(submission) {
                phase = .stable(.awaitingPrompt(observedOutput: false))
                submissionCount &+= 1
            }
        case .awaitingPrompt:
            markOutputObserved()
        case .seekingInitialPrompt:
            break
        }
    }

    private var currentLineHasVisibleContent: Bool {
        if logicalLineOverflowed {
            return overflowedLineHadVisibleContent
        }
        return visibleByteCount > 0
    }

    private mutating func markOutputObserved() {
        guard case .stable(.awaitingPrompt(let observedOutput)) = phase,
              !observedOutput,
              currentLineHasVisibleContent,
              !configuration.waitingPromptLineBytes.contains(logicalLine) else {
            return
        }
        phase = .stable(.awaitingPrompt(observedOutput: true))
    }

    private mutating func setPendingConfirmation(_ confirmation: PromptLineTurnConfirmation?) {
        guard pendingConfirmation != confirmation else { return }
        pendingConfirmation = confirmation
        confirmationRevision &+= 1
    }

    private static func isVisibleContentByte(_ byte: UInt8) -> Bool {
        byte > 0x20 && byte != 0x7F
    }

    private func containsVisibleContent<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        bytes.contains(where: Self.isVisibleContentByte)
    }

    private mutating func resetLogicalLine() {
        logicalLine.removeAll(keepingCapacity: true)
        logicalLineOverflowed = false
        visibleByteCount = 0
        unstoredLineByteCount = 0
        overflowedLineStartedWithPrompt = false
        overflowedSubmissionHadVisibleContent = false
        overflowedLineHadVisibleContent = false
    }
}
