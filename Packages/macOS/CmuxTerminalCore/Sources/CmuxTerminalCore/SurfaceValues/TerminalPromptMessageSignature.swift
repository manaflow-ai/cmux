/// Bounded cryptographic identity for a whitespace-normalized prompt body.
struct TerminalPromptMessageSignature: Equatable, Sendable {
    let digest: [UInt8]
    let byteCount: Int
}
