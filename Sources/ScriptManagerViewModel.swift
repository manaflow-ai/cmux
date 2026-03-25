import Foundation

/// View model for the Script Manager window.
/// Manages script list, selection, and editing state.
@MainActor
final class ScriptManagerViewModel: ObservableObject {
    @Published var scriptNames: [String] = []
    @Published var selectedName: String?
    @Published var editorText: String = ""
    @Published private(set) var isDirty: Bool = false

    private var loadedText: String = ""
    private let repo = ScriptRepository.shared

    func reload() {
        scriptNames = repo.listScripts()
        if let selected = selectedName, scriptNames.contains(selected) {
            loadScript(named: selected)
        } else if let first = scriptNames.first {
            selectScript(named: first)
        } else {
            selectedName = nil
            editorText = ""
            loadedText = ""
            isDirty = false
        }
    }

    func selectScript(named name: String) {
        selectedName = name
        loadScript(named: name)
    }

    func save() {
        guard let name = selectedName else { return }
        try? repo.saveScript(named: name, content: editorText)
        loadedText = editorText
        isDirty = false
    }

    func revert() {
        guard let name = selectedName else { return }
        loadScript(named: name)
    }

    func addScript() {
        var baseName = String(
            localized: "scriptManager.newScriptName",
            defaultValue: "New Script"
        )
        var counter = 1
        while repo.hasScript(named: baseName) {
            counter += 1
            baseName = String(
                localized: "scriptManager.newScriptNameNumbered",
                defaultValue: "New Script \(counter)"
            )
        }
        let defaultContent = "#!/bin/bash\n# New script\n"
        try? repo.saveScript(named: baseName, content: defaultContent)
        reload()
        selectScript(named: baseName)
    }

    func duplicateSelected() {
        guard let name = selectedName,
              let content = repo.getScript(named: name) else { return }
        var copyName = "\(name) Copy"
        var counter = 1
        while repo.hasScript(named: copyName) {
            counter += 1
            copyName = "\(name) Copy \(counter)"
        }
        try? repo.saveScript(named: copyName, content: content)
        reload()
        selectScript(named: copyName)
    }

    func deleteSelected() {
        guard let name = selectedName else { return }
        try? repo.deleteScript(named: name)
        selectedName = nil
        editorText = ""
        loadedText = ""
        isDirty = false
        reload()
    }

    func textDidChange(_ newText: String) {
        editorText = newText
        isDirty = newText != loadedText
    }

    // MARK: - Private

    private func loadScript(named name: String) {
        editorText = repo.getScript(named: name) ?? ""
        loadedText = editorText
        isDirty = false
    }
}
