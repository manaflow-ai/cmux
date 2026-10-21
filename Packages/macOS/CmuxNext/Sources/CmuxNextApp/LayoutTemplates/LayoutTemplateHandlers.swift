import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette
import Foundation

/// Layout templates (`LayoutTemplateLibrary`): Save Layout as Template… (`saveLayoutTemplate`),
/// New Workspace from Template… (`palette.layout.open`) and Manage Layout Templates…
/// (`manageLayouts`). Each entrypoint (palette, keyboard, the workspace row's menu, the CLI and
/// MCP through `action.run`) runs the same handler; the palette asks for a missing name or
/// template. A template is built into its new workspace by the path Duplicate Workspace uses
/// (`WorkspaceStructureHandlers.build`).
enum LayoutTemplateHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        Task { await services.layoutTemplates.load() }
        let suggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak services] source in
            guard source == ActionSuggestions.layoutTemplates else { return suggestions?(source) ?? [] }
            return services?.layoutTemplates.templates.map { ActionEnumCase(value: $0.name, title: $0.name) } ?? []
        }
        registry.bind("saveLayoutTemplate", run: { try save(context, $0) })
        registry.bind("palette.layout.open", run: { open(context, $0) })
        services.palette.sources.actionPages["manageLayouts"] = { [weak services] in services.map(managePage) }
        registry.bind("manageLayouts", run: { _ in
            guard !services.layoutTemplates.templates.isEmpty else { throw ActionFailure.invalidTarget(LayoutTemplateStrings.noTemplates) }
            services.palette.show(page: managePage(services), relativeTo: context.activeWindow?.window)
        })
    }

    /// Saves the target workspace's layout (as the store mirrors it now) under the `name` argument.
    private static func save(_ context: AppActionContext, _ invocation: ActionInvocation) throws {
        let workspace = try context.workspace(invocation).model
        let name = (invocation["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ActionFailure.invalidTarget(LayoutTemplateStrings.nameRequired) }
        let blueprint = WorkspaceBlueprint(workspace), library = context.services.layoutTemplates
        context.services.registry.track(Task { @MainActor in
            do {
                try await library.save(name: name, blueprint: blueprint)
                return nil
            } catch {
                return ActionWorkFailure("save layout template", error)
            }
        })
    }

    /// Builds a new workspace from the `template` argument's template: below the target workspace
    /// on its machine when one is named (its row's menu), else on the active machine in the active
    /// window, at `workspaces.newPlacement`. The workspace is named after the template.
    private static func open(_ context: AppActionContext, _ invocation: ActionInvocation) {
        let services = context.services, windows = services.windows, library = services.layoutTemplates
        let requested = invocation["template"]?.stringValue ?? ""
        let row = invocation.target.flatMap { $0.kind == .workspace ? services.workspace(id: $0.id) : nil }
        let daemon = row.flatMap { services.machines.daemon(forWorkspace: $0.id) } ?? services.activeDaemon
        let target = windows.targetWindow(preferring: row.flatMap { windows.registry.value.owner(of: $0.id) } ?? context.activeWindow?.state.id)
        services.registry.track(Task { @MainActor in
            await library.load()
            guard let template = library.template(named: requested) else {
                let blank = requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let reason = !blank ? LayoutTemplateStrings.noTemplate(requested)
                    : library.templates.isEmpty ? LayoutTemplateStrings.noTemplates : LayoutTemplateStrings.templateRequired
                services.registry.refuse(reason)
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
            return await WorkspaceStructureHandlers.build(template.blueprint, name: template.name, slot: row.map { WorkspaceSlot.below($0.id) },
                                                          on: daemon, into: target, label: "new workspace from template",
                                                          services: services, tracks: false).value
        })
    }

    /// Manage Layout Templates: one row per template; Return builds a workspace from it, the
    /// row's actions rename or delete it.
    static func managePage(_ services: AppServices) -> PalettePageSpec {
        let library = services.layoutTemplates
        let provider = AsyncPaletteProvider(id: "layoutTemplates.manage") { [weak services] in
            guard let services else { return [] }
            await library.settled()
            return library.templates.map { item(for: $0, services: services) }
        }
        return PalettePageSpec(id: "layoutTemplates.manage", title: LayoutTemplateStrings.manageTitle,
                               placeholder: LayoutTemplateStrings.managePlaceholder, symbol: "square.grid.3x3.square", providers: [provider])
    }

    private static func item(for template: LayoutTemplate, services: AppServices) -> PaletteItem {
        let library = services.layoutTemplates, registry = services.registry, id = template.id
        let panes = template.blueprint.screens.flatMap(\.columns).map(\.root.paneCount).reduce(0, +)
        let rename = PaletteTextInputSpec(
            id: "layoutTemplate.rename:\(id)", title: LayoutTemplateStrings.renameTitle,
            placeholder: LayoutTemplateStrings.namePlaceholder, initialText: template.name, skipsUnchangedText: true,
            submitTitle: { LayoutTemplateStrings.renameTo($0) },
            submit: { text in
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    registry.refuse(LayoutTemplateStrings.nameRequired)
                    return
                }
                Task { @MainActor in
                    do { try await library.rename(id, to: name) } catch LayoutTemplateRepository.Failure.nameTaken {
                        registry.refuse(LayoutTemplateStrings.nameTaken(name))
                    } catch {
                        registry.refuse(String(describing: error))
                    }
                }
            })
        return PaletteItem(
            id: "layoutTemplate:\(id)", title: template.name, subtitle: LayoutTemplateStrings.panes(panes),
            symbol: "square.grid.2x2", keywords: [template.blueprint.name],
            primary: PaletteCommand(id: "open", title: LayoutTemplateStrings.newWorkspace, symbol: "return", effect: .perform {
                _ = registry.perform("palette.layout.open", invocation: ActionInvocation(arguments: ["template": .string(template.name)]))
            }),
            secondary: [
                PaletteCommand(id: "rename", title: LayoutTemplateStrings.rename, symbol: "pencil", effect: .textInput(rename)),
                PaletteCommand(id: "delete", title: LayoutTemplateStrings.delete, symbol: "trash", isDestructive: true,
                               effect: .performKeepingOpen { library.deleteLater(id) }),
            ])
    }
}
