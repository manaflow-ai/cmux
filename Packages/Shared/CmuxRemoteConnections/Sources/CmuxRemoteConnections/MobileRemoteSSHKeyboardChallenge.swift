public import Foundation

/// A transient multi-factor keyboard-interactive challenge.
public struct MobileRemoteSSHKeyboardChallenge: Equatable, Sendable {
    /// Server challenge name.
    public let name: String
    /// Server instructions.
    public let instruction: String
    /// Ordered prompts requiring transient user responses.
    public let prompts: [MobileRemoteSSHKeyboardPrompt]

    /// Creates a bounded challenge.
    /// - Parameters:
    ///   - name: Server challenge name.
    ///   - instruction: Server instruction.
    ///   - prompts: Ordered response prompts.
    /// - Throws: Invalid-challenge for oversized metadata or too many prompts.
    public init(name: String, instruction: String, prompts: [MobileRemoteSSHKeyboardPrompt]) throws {
        guard name.utf8.count <= 4096, instruction.utf8.count <= 4096,
              prompts.count <= 32,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !instruction.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MobileRemoteSSHKeyboardError.invalidChallenge
        }
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}
