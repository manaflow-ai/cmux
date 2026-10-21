import CmuxNextActions

/// The file explorer's actions (Open Selection, Open Selection (Finder Style),
/// Open in cmux, Reveal in Finder, Copy Path, Copy Relative Path, Open With…):
/// keys, the explorer's own menu, the palette and `cmux sidebar ...` all run
/// these on the active window's explorer selection. They need
/// `fileExplorerFocused`, which the explorer's list publishes while it has the
/// keyboard. Work is tracked, so a CLI run answers with its failure.
enum FileExplorerHandlers {
    static func bind(into registry: ActionRegistry, explorer: @escaping @MainActor () -> FileExplorerModel?,
                     effects: any FileExplorerEffects) {
        func work(_ id: ActionID, _ body: @escaping @MainActor (ActionInvocation, FileExplorerCommands) async throws -> Void) {
            registry.bind(id, run: { invocation in
                guard let model = explorer() else { throw ActionFailure(message: FileExplorerStrings.noExplorer) }
                let commands = FileExplorerCommands(model: model, effects: effects)
                // task-owner: the action run; a capturing caller (CLI, MCP) awaits it through the registry.
                registry.track(Task { @MainActor in
                    do {
                        try await body(invocation, commands)
                        return nil
                    } catch {
                        let reason = (error as? FileExplorerError)?.reason ?? String(describing: error)
                        registry.refuse(reason)
                        return ActionWorkFailure(refusal: .unavailable, reason: reason)
                    }
                })
            })
        }
        work("fileExplorerOpenSelection") { try await $1.openSelection() }
        work("fileExplorerOpenSelectionFinderAlias") { try await $1.openSelection() }
        work("fileExplorerOpenInCmux") { try $1.openInCmux() }
        work("fileExplorerReveal") { try $1.revealInFinder() }
        work("fileExplorerCopyPath") { try $1.copyPath() }
        work("fileExplorerCopyRelativePath") { try $1.copyRelativePath() }
        work("fileExplorerOpenWith") { invocation, commands in
            guard let app = invocation["app"]?.stringValue, !app.isEmpty else { throw FileExplorerError.noSuchApp("") }
            try await commands.open(withApp: app)
        }
    }
}
