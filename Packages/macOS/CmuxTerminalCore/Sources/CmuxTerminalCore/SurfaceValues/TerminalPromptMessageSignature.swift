/// Bounded in-process identity for a whitespace-normalized prompt body.
struct TerminalPromptMessageSignature: Equatable, Sendable {
    let primaryHash: UInt64
    let secondaryHash: UInt64
    let byteCount: Int
}
