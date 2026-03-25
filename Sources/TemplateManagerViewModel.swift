import Foundation

/// View model for the Template Manager window.
/// Manages template list, selection, editing state, and YAML validation.
@MainActor
final class TemplateManagerViewModel: ObservableObject {
    @Published var templateNames: [String] = []
    @Published var selectedName: String?
    @Published var editorText: String = ""
    @Published var errorMessage: String?
    @Published private(set) var isDirty: Bool = false

    private var loadedText: String = ""
    private let repo = TemplateRepository.shared

    func reload() {
        templateNames = repo.listTemplates()
        if let selected = selectedName, templateNames.contains(selected) {
            loadTemplate(named: selected)
        } else if let first = templateNames.first {
            selectTemplate(named: first)
        } else {
            selectedName = nil
            editorText = ""
            loadedText = ""
            isDirty = false
            errorMessage = nil
        }
    }

    func selectTemplate(named name: String) {
        selectedName = name
        loadTemplate(named: name)
    }

    func save() {
        guard let name = selectedName else { return }
        // Validate YAML before saving
        do {
            _ = try TemplateYamlParser.parse(editorText)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            try repo.saveTemplate(named: name, rawYaml: editorText)
            loadedText = editorText
            isDirty = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revert() {
        guard let name = selectedName else { return }
        loadTemplate(named: name)
    }

    func addTemplate() {
        var baseName = String(
            localized: "templateManager.newTemplateName",
            defaultValue: "New Template"
        )
        var counter = 1
        while repo.hasTemplate(named: baseName) {
            counter += 1
            baseName = String(
                localized: "templateManager.newTemplateNameNumbered",
                defaultValue: "New Template \(counter)"
            )
        }
        let defaultContent = """
        root:
          title: Terminal
          children:
            - title: Shell
              command: ""
        """
        try? repo.saveTemplate(named: baseName, rawYaml: defaultContent)
        reload()
        selectTemplate(named: baseName)
    }

    func duplicateSelected() {
        guard let name = selectedName,
              let yaml = repo.rawYaml(named: name) else { return }
        var copyName = "\(name) Copy"
        var counter = 1
        while repo.hasTemplate(named: copyName) {
            counter += 1
            copyName = "\(name) Copy \(counter)"
        }
        try? repo.saveTemplate(named: copyName, rawYaml: yaml)
        reload()
        selectTemplate(named: copyName)
    }

    func deleteSelected() {
        guard let name = selectedName else { return }
        try? repo.deleteTemplate(named: name)
        selectedName = nil
        editorText = ""
        loadedText = ""
        isDirty = false
        errorMessage = nil
        reload()
    }

    func textDidChange(_ newText: String) {
        editorText = newText
        isDirty = newText != loadedText
        errorMessage = nil
    }

    // MARK: - Private

    private func loadTemplate(named name: String) {
        if let yaml = repo.rawYaml(named: name) {
            editorText = yaml
            loadedText = yaml
        } else {
            editorText = ""
            loadedText = ""
        }
        isDirty = false
        errorMessage = nil
    }
}
