import Foundation

/// Socket API commands for project opening and template-based project creation.
extension TerminalController {

    // MARK: - Project Open

    func v2ProjectOpen(params: [String: Any]) -> V2CallResult {
        guard let path = params["path"] as? String else {
            return .err(code: "missing_param", message: "Missing 'path'", data: nil)
        }
        let resolvedPath = (path as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .err(code: "not_directory", message: "Path is not a directory: \(path)", data: nil)
        }

        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }

            // Dedupe: check all windows for a parent workspace already targeting this directory
            let canonicalPath = dirURL.resolvingSymlinksInPath().path
            if let existing = findExistingProjectWorkspace(canonicalPath: canonicalPath, targetTm: tm) {
                return existing
            }

            // Try reading .cmux.yaml
            let configURL = dirURL.appendingPathComponent(".cmux.yaml")
            if let yamlContent = try? String(contentsOf: configURL, encoding: .utf8) {
                do {
                    let result = try CmuxConfigParser.parse(
                        yaml: yamlContent,
                        projectDirectory: dirURL,
                        scriptRepository: ScriptRepository.shared
                    )
                    // Create parent workspace for the project
                    let parentWs = tm.addWorkspace(
                        workingDirectory: dirURL.path,
                        select: true
                    )
                    parentWs.title = result.projectName
                    parentWs.customColor = result.projectColor

                    let scriptRunner = StartupScriptRunner()
                    for tabDef in result.tabDefinitions {
                        let childWs = tm.addWorkspace(
                            workingDirectory: dirURL.path,
                            select: false,
                            skipStandaloneRegistration: true
                        )
                        childWs.title = tabDef.title
                        tm.groupManager.addChildId(childWs.id, to: parentWs.id)
                        if let scriptName = tabDef.startupScript,
                           let scriptContent = ScriptRepository.shared.getScript(named: scriptName),
                           scriptRunner.shouldRunScript(isRestore: false),
                           let panelId = childWs.focusedPanelId ?? childWs.panels.values.first(where: { $0 is TerminalPanel })?.id {
                            scriptRunner.scheduleScript(content: scriptContent, workspace: childWs, panelId: panelId)
                        }
                    }
                    tm.items = tm.groupManager.items
                    tm.selectedTabId = parentWs.id
                    return .ok(["workspace_id": parentWs.id.uuidString, "dedupe": false])
                } catch {
                    // Fall through to single-workspace fallback on parse error
                }
            }

            // Fallback: create a single workspace with the directory name
            let projectName = dirURL.lastPathComponent
            let ws = tm.addWorkspace(workingDirectory: dirURL.path, select: true)
            ws.title = projectName
            return .ok(["workspace_id": ws.id.uuidString, "dedupe": false])
        }
    }

    // MARK: - Project Open Template

    func v2ProjectOpenTemplate(params: [String: Any]) -> V2CallResult {
        guard let path = params["path"] as? String else {
            return .err(code: "missing_param", message: "Missing 'path'", data: nil)
        }
        guard let templateName = params["template"] as? String else {
            return .err(code: "missing_param", message: "Missing 'template'", data: nil)
        }

        let resolvedPath = (path as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .err(code: "not_directory", message: "Path is not a directory: \(path)", data: nil)
        }

        let template: WorkspaceTemplate
        do {
            template = try TemplateRepository.shared.getTemplate(named: templateName)
        } catch {
            return .err(code: "not_found", message: "Template '\(templateName)' not found", data: nil)
        }

        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }

            // Dedupe: check all windows for a parent workspace already targeting this directory
            let canonicalPath = dirURL.resolvingSymlinksInPath().path
            if let existing = findExistingProjectWorkspace(canonicalPath: canonicalPath, targetTm: tm) {
                return existing
            }

            let scriptRunner = StartupScriptRunner()

            // Create root workspace
            let rootWs = tm.addWorkspace(workingDirectory: dirURL.path, select: true)
            rootWs.title = template.root.title
            if let color = template.root.color {
                rootWs.customColor = color
            }

            // Schedule root command if any
            if let command = template.root.command,
               let panelId = rootWs.focusedPanelId ?? rootWs.panels.values.first(where: { $0 is TerminalPanel })?.id {
                scriptRunner.scheduleCommand(command, workspace: rootWs, panelId: panelId)
            }

            // Create children recursively
            var createdIds: [String] = [rootWs.id.uuidString]
            createChildWorkspaces(
                children: template.root.children,
                parentId: rootWs.id,
                workingDirectory: dirURL.path,
                tabManager: tm,
                scriptRunner: scriptRunner,
                createdIds: &createdIds
            )

            tm.items = tm.groupManager.items
            tm.selectedTabId = rootWs.id
            return .ok([
                "workspace_id": rootWs.id.uuidString,
                "workspace_ids": createdIds,
                "dedupe": false
            ])
        }
    }

    /// Recursively create child workspaces from a template node tree.
    private func createChildWorkspaces(
        children: [TemplateNode],
        parentId: UUID,
        workingDirectory: String,
        tabManager tm: TabManager,
        scriptRunner: StartupScriptRunner,
        createdIds: inout [String]
    ) {
        for child in children {
            let ws = tm.addWorkspace(
                workingDirectory: workingDirectory,
                select: false,
                eagerLoadTerminal: true,
                skipStandaloneRegistration: true
            )
            ws.title = child.title
            if let color = child.color {
                ws.customColor = color
            }
            tm.groupManager.addChildId(ws.id, to: parentId)
            createdIds.append(ws.id.uuidString)

            if let command = child.command,
               let panelId = ws.focusedPanelId ?? ws.panels.values.first(where: { $0 is TerminalPanel })?.id {
                scriptRunner.scheduleCommand(command, workspace: ws, panelId: panelId)
            }

            // Recurse for nested children (max depth enforced by group manager)
            if !child.children.isEmpty {
                createChildWorkspaces(
                    children: child.children,
                    parentId: ws.id,
                    workingDirectory: workingDirectory,
                    tabManager: tm,
                    scriptRunner: scriptRunner,
                    createdIds: &createdIds
                )
            }
        }
    }

    // MARK: - Legacy Template Installation

    func v2GroupInstallTemplate(params: [String: Any]) -> V2CallResult {
        guard let parentIdStr = params["group_id"] as? String ?? params["workspace_id"] as? String,
              let parentId = UUID(uuidString: parentIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'workspace_id'", data: nil)
        }
        guard let templateName = params["template"] as? String else {
            return .err(code: "missing_param", message: "Missing 'template'", data: nil)
        }

        let template: WorkspaceTemplate
        do {
            template = try TemplateRepository.shared.getTemplate(named: templateName)
        } catch {
            return .err(code: "not_found", message: "Template '\(templateName)' not found", data: nil)
        }

        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let parentWs = tm.workspace(for: parentId) else {
                return V2CallResult.err(code: "not_found", message: "Workspace not found", data: nil)
            }

            let workDir = parentWs.currentDirectory
            let scriptRunner = StartupScriptRunner()
            var createdIds: [String] = []

            for child in template.root.children {
                let ws = tm.addWorkspace(
                    workingDirectory: workDir,
                    select: false,
                    skipStandaloneRegistration: true
                )
                ws.title = child.title
                if let color = child.color {
                    ws.customColor = color
                }
                tm.groupManager.addChildId(ws.id, to: parentId)
                createdIds.append(ws.id.uuidString)

                if let command = child.command,
                   let panelId = ws.focusedPanelId ?? ws.panels.values.first(where: { $0 is TerminalPanel })?.id {
                    scriptRunner.scheduleCommand(command, workspace: ws, panelId: panelId)
                }
            }
            tm.items = tm.groupManager.items
            return .ok(["workspace_id": parentId.uuidString, "workspace_ids": createdIds])
        }
    }

    // MARK: - Private

    /// Search all windows' TabManagers for a parent workspace already targeting this directory.
    private func findExistingProjectWorkspace(
        canonicalPath: String, targetTm: TabManager
    ) -> V2CallResult? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        for tm in appDelegate.allTabManagers() {
            for wsId in tm.items {
                guard let ws = tm.workspace(for: wsId),
                      ws.hasChildren else { continue }
                let wsPath = URL(fileURLWithPath: ws.currentDirectory)
                    .resolvingSymlinksInPath().path
                if wsPath == canonicalPath {
                    tm.selectedTabId = ws.id
                    tm.window?.makeKeyAndOrderFront(nil)
                    return .ok(["workspace_id": ws.id.uuidString, "dedupe": true])
                }
            }
        }
        return nil
    }
}
