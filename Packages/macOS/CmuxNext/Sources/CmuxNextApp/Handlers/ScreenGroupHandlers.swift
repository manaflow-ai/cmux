import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// Screen group actions (Chrome tab group parity for the screen bar). The
/// group is resolved before the capability check, so an unknown group is
/// reported as such on every daemon.
enum ScreenGroupHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindMembership(registry, ctx)
        bindEdits(registry, ctx)
        bindMoves(registry, ctx)
        bindSaved(registry, ctx)
    }

    private static func group(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> ScreenGroupRef? {
        guard let ref = ctx.screenGroup(invocation), ctx.require(DaemonCapabilities.screenGroups, on: ref.daemon) else { return nil }
        return ref
    }

    private static func bindMembership(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("screenGroup.create", invoke: { invocation in
            guard let ref = ctx.screen(invocation), ctx.require(DaemonCapabilities.screenGroups, on: ref.daemon) else { return }
            guard !ref.screen.pinned else { return ctx.refuse(ScreenStrings.pinnedCannotGroup) }
            let color = invocation["color"]?.stringValue.flatMap(GroupColor.init(rawValue:))
            ScreenGroupCommands.create([ref.screen], in: ref.workspace, name: invocation["name"]?.stringValue, color: color, daemon: ref.daemon)
        })
        registry.bind("screenGroup.addScreen", invoke: { invocation in
            guard let screen = ctx.screen(ActionInvocation(target: invocation.target?.kind == .screen ? invocation.target : nil)) else { return }
            guard invocation["group"] != nil || ctx.refuse(RefusalStrings.groupArgumentRequired) != Optional<Bool>.none,
                  let ref = group(invocation, ctx) else { return }
            guard !screen.screen.pinned else { return ctx.refuse(ScreenStrings.pinnedCannotGroup) }
            ScreenGroupCommands.add([screen.screen], to: ref.group.id, daemon: ref.daemon)
        })
        registry.bind("screenGroup.removeScreen", invoke: { invocation in
            guard let ref = ctx.screen(invocation), ctx.require(DaemonCapabilities.screenGroups, on: ref.daemon) else { return }
            guard ref.screen.group != nil else { return ctx.refuse(ScreenStrings.screenNotInGroup) }
            ScreenGroupCommands.remove([ref.screen], daemon: ref.daemon)
        })
    }

    private static func bindEdits(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("screenGroup.newScreen", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            ScreenGroupCommands.newScreen(in: ref)
        })
        registry.bind("screenGroup.rename", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            if let name = invocation["name"]?.stringValue {
                return ScreenGroupCommands.update(ref.group.id, name: name, daemon: ref.daemon)
            }
            guard let window = ctx.services.windows.active?.window ?? ctx.refuse(RefusalStrings.nameArgumentRequired) else { return }
            RenamePrompt.run(title: ScreenStrings.groupNamePromptTitle, initial: ref.group.name, in: window) { name in
                ScreenGroupCommands.update(ref.group.id, name: name, daemon: ref.daemon)
            }
        })
        registry.bind("screenGroup.setColor", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            guard let color = invocation["color"]?.stringValue.flatMap(GroupColor.init(rawValue:))
                ?? ctx.refuse(RefusalStrings.colorArgumentRequired) else { return }
            ScreenGroupCommands.update(ref.group.id, color: color, daemon: ref.daemon)
        })
        for color in GroupColor.allCases {
            registry.bind(ActionID(rawValue: "screenGroup.color.\(color.rawValue)"), invoke: { invocation in
                guard let ref = group(invocation, ctx) else { return }
                ScreenGroupCommands.update(ref.group.id, color: color, daemon: ref.daemon)
            })
        }
        let collapse: [(ActionID, (Bool) -> Bool)] = [("screenGroup.toggleCollapsed", { !$0 }), ("screenGroup.collapse", { _ in true }),
                                                      ("screenGroup.expand", { _ in false })]
        for (id, next) in collapse {
            registry.bind(id, invoke: { invocation in
                guard let ref = group(invocation, ctx) else { return }
                ScreenGroupCommands.setCollapsed(ref, next(ref.group.collapsed))
            })
        }
        registry.bind("screenGroup.ungroup", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            ScreenGroupCommands.ungroup(ref.group.id, daemon: ref.daemon)
        })
        registry.bind("screenGroup.close", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            ScreenGroupCommands.close(ref, services: ctx.services)
        })
    }

    private static func bindMoves(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        for (id, forward) in [("screenGroup.moveLeft", false), ("screenGroup.moveRight", true)] as [(ActionID, Bool)] {
            registry.bind(id, invoke: { invocation in
                guard let ref = group(invocation, ctx) else { return }
                guard let index = ScreenGroupReorder.targetIndex(of: ref.group.id, forward: forward, in: ref.workspace.screens)
                    ?? ctx.refuse(RefusalStrings.groupAtEdge) else { return }
                ScreenGroupCommands.move(ref.group.id, to: index, daemon: ref.daemon)
            })
        }
        registry.bind("screenGroup.moveToWorkspace", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            guard let id = invocation["workspace"]?.targetValue?.id ?? invocation["workspace"]?.stringValue,
                  let target = ctx.services.workspace(id: id) ?? ctx.refuse(RefusalStrings.noWorkspace(invocation["workspace"]?.stringValue ?? "")) else { return }
            guard target !== ref.workspace else { return ctx.refuse(ScreenStrings.sameWorkspace) }
            ScreenGroupCommands.move(ref.group.id, toWorkspace: target, daemon: ref.daemon)
        })
        for (id, newWindow) in [("screenGroup.moveToNewWorkspace", false), ("screenGroup.moveToNewWindow", true)] as [(ActionID, Bool)] {
            registry.bind(id, invoke: { invocation in
                guard let ref = group(invocation, ctx) else { return }
                ScreenGroupCommands.moveToNewWorkspace(ref.group.id, daemon: ref.daemon, services: ctx.services, newWindow: newWindow)
            })
        }
    }

    private static func bindSaved(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("screenGroup.save", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            ScreenGroupCommands.save(ref.group.id, daemon: ref.daemon)
        })
        registry.bind("screenGroup.unsave", invoke: { invocation in
            guard let ref = group(invocation, ctx) else { return }
            guard ref.group.savedID != nil else { return ctx.refuse(RefusalStrings.groupNotSaved) }
            ScreenGroupCommands.unsave(ref.group.id, daemon: ref.daemon)
        })
        registry.bind("screenGroup.reopenSaved", invoke: { invocation in
            guard let content = ctx.content(invocation), ctx.require(DaemonCapabilities.screenGroups, on: content.daemon) else { return }
            guard let saved = invocation["saved"]?.stringValue ?? ctx.refuse(RefusalStrings.groupArgumentRequired) else { return }
            let id = SavedScreenGroupID(rawValue: saved), workspace = content.workspace.handle
            content.daemon.send("reopen-saved-screen-group") { _ = try await $0.reopenSavedScreenGroup(id, in: workspace) }
        })
        registry.bind("screenGroup.deleteSaved", invoke: { invocation in
            guard ctx.require(DaemonCapabilities.screenGroups, on: ctx.services.activeDaemon) else { return }
            guard let saved = invocation["saved"]?.stringValue ?? ctx.refuse(RefusalStrings.groupArgumentRequired) else { return }
            let id = SavedScreenGroupID(rawValue: saved)
            ctx.services.activeDaemon.send("delete-saved-screen-group") { try await $0.deleteSavedScreenGroup(id) }
        })
    }
}

/// Where Move Screen Group Left/Right puts a group: past the neighboring
/// screen or group on that side, never into the pinned run.
enum ScreenGroupReorder {
    @MainActor
    static func targetIndex(of group: ScreenGroupID, forward: Bool, in screens: [ScreenModel]) -> Int? {
        guard let first = screens.firstIndex(where: { $0.group == group }),
              let last = screens.lastIndex(where: { $0.group == group }) else { return nil }
        if forward {
            guard last + 1 < screens.count else { return nil }
            let neighbor = screens[last + 1]
            let span = neighbor.group.map { id in screens.filter { $0.group == id }.count } ?? 1
            return first + span
        }
        guard first > 0, !screens[first - 1].pinned else { return nil }
        let neighbor = screens[first - 1]
        let span = neighbor.group.map { id in screens.filter { $0.group == id }.count } ?? 1
        return first - span
    }
}
