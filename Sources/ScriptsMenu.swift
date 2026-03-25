import SwiftUI

/// Scripts menu added to the app's main menu bar via CommandMenu.
/// Provides access to run scripts, open templates, and manage both.
struct ScriptsMenuContent: View {
    let activeTabManager: TabManager

    var body: some View {
        runScriptSubmenu
        openTemplateSubmenu
        Divider()
        Button(String(localized: "menu.scripts.manageTemplates", defaultValue: "Manage Templates…")) {
            TemplateManagerWindowController.shared.show()
        }
        Button(String(localized: "menu.scripts.manageScripts", defaultValue: "Manage Scripts…")) {
            ScriptManagerWindowController.shared.show()
        }
    }

    // MARK: - Run Script

    @ViewBuilder
    private var runScriptSubmenu: some View {
        let scripts = ScriptRepository.shared.listScripts()
        let isAtPrompt = activeTabManager.selectedTab?.isFocusedPanelAtPrompt ?? false
        Menu(String(localized: "menu.scripts.runScript", defaultValue: "Run Script")) {
            ForEach(scripts, id: \.self) { scriptName in
                Button(scriptName) {
                    runScript(named: scriptName)
                }
                .disabled(!isAtPrompt)
            }
            if scripts.isEmpty {
                Text(String(localized: "menu.scripts.noScripts", defaultValue: "No Scripts"))
            }
        }
    }

    private func runScript(named scriptName: String) {
        guard let scriptContent = ScriptRepository.shared.getScript(named: scriptName),
              let terminalPanel = activeTabManager.selectedTab?.focusedTerminalPanel else { return }
        let lines = StartupScriptRunner.prepareScriptLines(scriptContent)
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        terminalPanel.sendInteractiveText(text)
    }

    // MARK: - Open Template

    @ViewBuilder
    private var openTemplateSubmenu: some View {
        let templates = TemplateRepository.shared.listTemplates()
        Menu(String(localized: "menu.scripts.openTemplate", defaultValue: "Open Template")) {
            ForEach(templates, id: \.self) { templateName in
                Button(templateName) {
                    openTemplate(named: templateName)
                }
            }
            if templates.isEmpty {
                Text(String(localized: "menu.scripts.noTemplates", defaultValue: "No Templates"))
            }
        }
    }

    private func openTemplate(named templateName: String) {
        guard let template = try? TemplateRepository.shared.getTemplate(named: templateName) else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "menu.scripts.openTemplate.panelTitle",
            defaultValue: "Choose Directory for Template"
        )
        panel.prompt = String(localized: "menu.scripts.openTemplate.panelPrompt", defaultValue: "Open")

        // Default to the focused tab's current directory if available
        if let currentDir = activeTabManager.selectedTab?.currentDirectory {
            panel.directoryURL = URL(fileURLWithPath: currentDir)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        activeTabManager.openTemplate(template, directory: url.path)
    }
}
