import CmuxNextDesign

/// RED STUB (R96 quit hook): the quit's unsaved step with no behavior yet.
@MainActor
enum QuitUnsavedStep {
    static let saveID = "save"
    static let dontSaveID = "dont-save"

    static func resolveInteractive(_ registry: QuitUnsavedRegistry, scope: CmuxDialogScope,
                                   center: CmuxDialogCenter = .shared) async -> Bool { true }

    static func spec(_ participants: [any QuitUnsavedParticipant], failures: [String: String]) -> CmuxDialogSpec {
        CmuxDialogSpec(title: QuitStrings.unsavedTitle, buttons: [])
    }

    static func saveUnattended(_ registry: QuitUnsavedRegistry) async -> [QuitFlushOutcome] { [] }

    static func refusal(_ outcomes: [QuitFlushOutcome]) -> String? { nil }
}
