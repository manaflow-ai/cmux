import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// Screen group actions (Chrome tab group parity for the screen bar), on
/// the daemon's `screen_group` state resources. Moving a group, moving it to
/// another workspace, and saved screen groups have no state operation yet and
/// are unavailable.
enum ScreenGroupHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindMembership(registry, ctx)
        bindEdits(registry, ctx)
        bindMoves(registry, ctx)
        bindSaved(registry, ctx)
    }

    private static func group(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> ScreenGroupRef? {
        ctx.screenGroup(invocation)
    }

    private static func bindMembership(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("screenGroup.create", invoke: { invocation in
            guard let ref = ctx.screen(invocation), ctx.requireScreenState(ref.screen) else { return }
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
            guard let ref = ctx.screen(invocation), ctx.requireScreenState(ref.screen) else { return }
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
        registry.bindUnavailable(["screenGroup.moveLeft", "screenGroup.moveRight", "screenGroup.moveToWorkspace",
                                  "screenGroup.moveToNewWorkspace", "screenGroup.moveToNewWindow"],
                                 ActionFailure.needsDaemonCapability("screen-group-move"))
    }

    private static func bindSaved(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bindUnavailable(["screenGroup.save", "screenGroup.unsave", "screenGroup.reopenSaved", "screenGroup.deleteSaved"],
                                 ActionFailure.needsDaemonCapability("saved-screen-groups"))
    }
}
