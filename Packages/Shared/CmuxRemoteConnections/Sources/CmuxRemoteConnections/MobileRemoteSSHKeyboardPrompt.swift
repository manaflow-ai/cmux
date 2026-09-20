public import Foundation

/// One server keyboard-interactive prompt, never persisted as a credential.
public struct MobileRemoteSSHKeyboardPrompt: Equatable, Sendable {
    /// Prompt text supplied by the server.
    public let text: String
    /// Whether the server allows the app to display the response while typing.
    public let echo: Bool

    /// Creates a bounded prompt.
    /// - Parameters:
    ///   - text: Prompt text, at most 4096 UTF-8 bytes.
    ///   - echo: Whether input may be echoed.
    /// - Throws: Invalid-prompt for oversized or control-character text.
    public init(text: String, echo: Bool) throws {
        guard text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 10 }) else {
            throw MobileRemoteSSHKeyboardError.invalidPrompt
        }
        self.text = text
        self.echo = echo
    }
}
