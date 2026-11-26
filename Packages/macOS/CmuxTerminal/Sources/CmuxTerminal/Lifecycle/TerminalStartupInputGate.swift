import Foundation

/// Keeps startup bytes out of the PTY until this shell generation reports a prompt.
struct TerminalStartupInputGate {
    private enum Phase {
        case awaitingPrompt(String)
        case consumed
    }

    private var generation: UUID?
    private var phase: Phase = .consumed

    mutating func stage(_ input: String?, generation: UUID) {
        guard self.generation != generation else { return }
        self.generation = generation
        phase = input.flatMap { $0.isEmpty ? nil : .awaitingPrompt($0) } ?? .consumed
    }

    mutating func cancel(generation: UUID) {
        self.generation = generation
        phase = .consumed
    }

    mutating func takeForPrompt(generation: UUID) -> String? {
        guard self.generation == generation, case .awaitingPrompt(let input) = phase else {
            return nil
        }
        // Consume before entering native input code, which can call back into the owner.
        phase = .consumed
        return input
    }
}
