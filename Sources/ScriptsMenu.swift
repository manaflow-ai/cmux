import SwiftUI

/// Scripts menu added to the app's main menu bar via CommandMenu.
/// Uses Equatable to minimize body re-evaluation. Resolves live state
/// (active tab manager, prompt state) only inside action closures,
/// not during menu rendering.
struct ScriptsMenuContent: View, Equatable {
    let scriptNames: [String]
    let templateNames: [String]

    static func == (lhs: ScriptsMenuContent, rhs: ScriptsMenuContent) -> Bool {
        lhs.scriptNames == rhs.scriptNames && lhs.templateNames == rhs.templateNames
    }

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
        let isAtPrompt = Self.resolveActiveTabManager()?.selectedTab?.isFocusedPanelAtPrompt ?? false
        Menu(String(localized: "menu.scripts.runScript", defaultValue: "Run Script")) {
            ForEach(scriptNames, id: \.self) { scriptName in
                Button(scriptName) {
                    runScript(named: scriptName)
                }
                .disabled(!isAtPrompt)
            }
            if scriptNames.isEmpty {
                Text(String(localized: "menu.scripts.noScripts", defaultValue: "No Scripts"))
            }
        }
    }

    private func runScript(named scriptName: String) {
        guard let scriptContent = ScriptRepository.shared.getScript(named: scriptName),
              let tabManager = Self.resolveActiveTabManager(),
              let terminalPanel = tabManager.selectedTab?.focusedTerminalPanel else { return }
        let lines = StartupScriptRunner.prepareScriptLines(scriptContent)
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        terminalPanel.sendInteractiveText(text)
    }

    // MARK: - Open Template

    @ViewBuilder
    private var openTemplateSubmenu: some View {
        Menu(String(localized: "menu.scripts.openTemplate", defaultValue: "Open Template")) {
            ForEach(templateNames, id: \.self) { templateName in
                Button(templateName) {
                    openTemplate(named: templateName)
                }
            }
            if templateNames.isEmpty {
                Text(String(localized: "menu.scripts.noTemplates", defaultValue: "No Templates"))
            }
        }
    }

    private func openTemplate(named templateName: String) {
        guard let template = try? TemplateRepository.shared.getTemplate(named: templateName),
              let tabManager = Self.resolveActiveTabManager() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "menu.scripts.openTemplate.panelTitle",
            defaultValue: "Choose Directory for Template"
        )
        panel.prompt = String(localized: "menu.scripts.openTemplate.panelPrompt", defaultValue: "Open")

        if let currentDir = tabManager.selectedTab?.currentDirectory {
            panel.directoryURL = URL(fileURLWithPath: currentDir)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        tabManager.openTemplate(template, directory: url.path)
    }

    // MARK: - Private

    private static func resolveActiveTabManager() -> TabManager? {
        AppDelegate.shared?.preferredTabManager(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }
}
