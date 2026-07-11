public import Foundation

/// Detects completed interactive turns from a raw PTY output stream.
///
/// The detector becomes ready after seeing the configured prompt on a logical
/// line. It then requires a non-empty echoed submission and subsequent output
/// before the prompt can complete a turn. ANSI CSI and OSC sequences are
/// ignored, while carriage returns and backspaces update the logical line.
public struct PromptLineTurnDetector: Sendable {
    private enum Phase: Sendable {
        case seekingInitialPrompt
        case readyForSubmission
        case awaitingPrompt(observedOutput: Bool)
    }

    private enum ControlSequence: Sendable {
        case none
        case escape
        case csi
        case osc
        case oscEscape
    }

    private static let maximumLogicalLineBytes = 4_096

    private let configuration: PromptLineTurnDetectionConfiguration
    private var phase: Phase = .seekingInitialPrompt
    private var controlSequence: ControlSequence = .none
    private var logicalLine: [UInt8] = []
    private var logicalLineOverflowed = false

    /// Creates a detector for one prompt-line configuration.
    ///
    /// - Parameter configuration: The exact prompt that brackets interactive turns.
    public init(configuration: PromptLineTurnDetectionConfiguration) {
        self.configuration = configuration
        logicalLine.reserveCapacity(configuration.promptBytes.count + 64)
    }

    /// Consumes one PTY output chunk and returns the number of completed turns.
    ///
    /// - Parameter data: Raw bytes read from the PTY.
    /// - Returns: The number of conservative prompt-return boundaries in this chunk.
    public mutating func consume(_ data: Data) -> Int {
        data.withUnsafeBytes { rawBuffer in
            consume(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Consumes one borrowed PTY output chunk and returns the number of completed turns.
    ///
    /// - Parameter bytes: Raw bytes read from the PTY.
    /// - Returns: The number of conservative prompt-return boundaries in this chunk.
    public mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var completions = 0
        for byte in bytes {
            completions += consume(byte)
        }
        return completions
    }

    private mutating func consume(_ byte: UInt8) -> Int {
        switch controlSequence {
        case .escape:
            switch byte {
            case UInt8(ascii: "["): controlSequence = .csi
            case UInt8(ascii: "]"): controlSequence = .osc
            default: controlSequence = .none
            }
            return 0
        case .csi:
            if (0x40...0x7E).contains(byte) {
                controlSequence = .none
            }
            return 0
        case .osc:
            if byte == 0x07 {
                controlSequence = .none
            } else if byte == 0x1B {
                controlSequence = .oscEscape
            }
            return 0
        case .oscEscape:
            controlSequence = byte == UInt8(ascii: "\\") ? .none : .osc
            return 0
        case .none:
            break
        }

        switch byte {
        case 0x1B:
            controlSequence = .escape
            return 0
        case 0x0A, 0x0D:
            handleLineBoundary()
            resetLogicalLine()
            return 0
        case 0x08, 0x7F:
            if !logicalLineOverflowed, !logicalLine.isEmpty {
                logicalLine.removeLast()
            }
            return evaluateLogicalLine()
        case 0x20...0x7E, 0x80...0xFF:
            appendToLogicalLine(byte)
            return evaluateLogicalLine()
        default:
            return 0
        }
    }

    private mutating func appendToLogicalLine(_ byte: UInt8) {
        guard !logicalLineOverflowed else { return }
        guard logicalLine.count < Self.maximumLogicalLineBytes else {
            logicalLine.removeAll(keepingCapacity: true)
            logicalLineOverflowed = true
            markOutputObserved()
            return
        }
        logicalLine.append(byte)
    }

    private mutating func evaluateLogicalLine() -> Int {
        guard !logicalLineOverflowed else { return 0 }
        let prompt = configuration.promptBytes

        switch phase {
        case .seekingInitialPrompt:
            if logicalLine == prompt {
                phase = .readyForSubmission
            }
        case .readyForSubmission:
            break
        case .awaitingPrompt(let observedOutput):
            if logicalLine == prompt {
                phase = .readyForSubmission
                return observedOutput ? 1 : 0
            }
            if !prompt.starts(with: logicalLine), containsVisibleContent(logicalLine) {
                phase = .awaitingPrompt(observedOutput: true)
            }
        }
        return 0
    }

    private mutating func handleLineBoundary() {
        switch phase {
        case .readyForSubmission:
            guard !logicalLineOverflowed,
                  logicalLine.starts(with: configuration.promptBytes) else {
                return
            }
            let submission = logicalLine.dropFirst(configuration.promptBytes.count)
            if containsVisibleContent(submission) {
                phase = .awaitingPrompt(observedOutput: false)
            }
        case .awaitingPrompt:
            markOutputObserved()
        case .seekingInitialPrompt:
            break
        }
    }

    private mutating func markOutputObserved() {
        guard case .awaitingPrompt(let observedOutput) = phase,
              !observedOutput,
              containsVisibleContent(logicalLine),
              logicalLine != configuration.promptBytes else {
            return
        }
        phase = .awaitingPrompt(observedOutput: true)
    }

    private func containsVisibleContent<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        bytes.contains { byte in
            byte > 0x20 && byte != 0x7F
        }
    }

    private mutating func resetLogicalLine() {
        logicalLine.removeAll(keepingCapacity: true)
        logicalLineOverflowed = false
    }
}
