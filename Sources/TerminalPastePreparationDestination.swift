/// The caller-specific result produced by the shared paste-preparation lane.
enum TerminalPastePreparationDestination: Codable, Sendable {
    case terminal
    case composer
}
