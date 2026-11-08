/// Describes UTF-8 text transported outside the worker's bounded JSON envelope.
struct TerminalPastePreparationWorkerTextPayload: Codable, Sendable {
    static let filename = "text-payload.txt"
    static let maximumByteCount = 16 * 1024 * 1024

    let destination: TerminalPastePreparationDestination
    let filename: String
}
