import Foundation

/// The value a paste-preparation worker leaves for its supervising process.
struct TerminalPastePreparationWorkerResponse: Codable, Sendable {
    let result: TerminalPastePreparationResult?
    let textPayload: TerminalPastePreparationWorkerTextPayload?
    let ownedTemporaryImageNames: [String]
}
