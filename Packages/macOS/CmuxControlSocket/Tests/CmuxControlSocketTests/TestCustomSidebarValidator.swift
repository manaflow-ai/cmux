import Foundation
@testable import CmuxControlSocket

struct TestCustomSidebarValidator: ControlCustomSidebarValidating {
    func validate(directory: URL, name requestedName: String?) -> ControlCustomSidebarValidationReport {
        let entries: [ControlCustomSidebarValidationEntry]
        switch requestedName {
        case .some("chosen"):
            entries = [entry(name: "chosen", directory: directory, isValid: true)]
        case .some("missing"):
            entries = [entry(
                name: "missing",
                directory: directory,
                isValid: false,
                errorMessage: "Sidebar file is missing."
            )]
        case .some(let name):
            entries = [entry(
                name: name,
                directory: directory,
                isValid: false,
                errorMessage: "Sidebar file is missing."
            )]
        case .none:
            entries = [
                entry(name: "broken", directory: directory, isValid: false, errorMessage: "Missing version"),
                entry(name: "ok", directory: directory, isValid: true),
            ]
        }
        return ControlCustomSidebarValidationReport(entries: entries)
    }

    private func entry(
        name: String,
        directory: URL,
        isValid: Bool,
        errorMessage: String? = nil
    ) -> ControlCustomSidebarValidationEntry {
        ControlCustomSidebarValidationEntry(
            name: name,
            path: directory.appendingPathComponent("\(name).json").path,
            kind: "json",
            isValid: isValid,
            errorMessage: errorMessage
        )
    }
}
