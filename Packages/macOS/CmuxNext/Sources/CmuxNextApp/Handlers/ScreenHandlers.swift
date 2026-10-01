import CmuxNextActions
import Foundation
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

/// Screen actions (tmux-style windows inside a workspace). Screens have no
/// chrome until a workspace holds two or more; then the bottom screen bar
/// shows them. Every verb runs through `ScreenCommands`, the same path the
/// bar's clicks, drags, and editor use.
enum ScreenHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindLifecycle(registry, ctx)
        bindNavigation(registry, ctx)
        bindMoves(registry, ctx)
        ScreenAppearanceHandlers.bind(into: registry, context: ctx)
        ScreenGroupHandlers.bind(into: registry, context: ctx)
    }

    private static func bindLifecycle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("screen.new", invoke: { invocation in
            guard let content = ctx.content(invocation) else { return }
            ScreenCommands.create(in: content.workspace, daemon: content.daemon, content: content)
        })
        registry.bind("screen.newWith", invoke: { invocation in
            guard let content = ctx.content(invocation) else { return }
            let color = invocation["color"]?.stringValue
            if let color, GroupColor(rawValue: color) == nil { return ctx.refuse(RefusalStrings.colorArgumentRequired) }
            let spec = ScreenSpec(name: invocation["name"]?.stringValue.flatMap(nonEmpty), color: color,
                                  icon: invocation["icon"]?.stringValue.flatMap(nonEmpty))
            // `new-screen` takes no directory on this daemon (its first terminal
            // starts in the default one); say so rather than drop the argument.
            if invocation["cwd"]?.stringValue.flatMap(nonEmpty) != nil {
                return ctx.refuse(RefusalStrings.needsDaemonCapability("new-screen-cwd"))
            }
            if !spec.isEmpty, !ctx.requireScreenState(in: content.workspace) { return }
            ScreenCommands.create(in: content.workspace, daemon: content.daemon, content: content, spec: spec)
        })
        registry.bind("screen.duplicate", invoke: { invocation in
            guard let ref = ctx.screen(invocation), ctx.requireScreenState(ref.screen) else { return }
            ScreenCommands.duplicate(ref)
        })
        registry.bind("screen.close", invoke: { invocation in
            guard let ref = ctx.screen(invocation) else { return }
            ScreenCommands.close([ref.screen], in: ref.workspace, daemon: ref.daemon, services: ctx.services)
        })
        let closeVariants: [(ActionID, (ScreenRef) -> [ScreenModel])] = [
            ("screen.closeOthers", { ref in ref.workspace.screens.filter { $0 !== ref.screen && !$0.pinned } }),
            ("screen.closeToRight", { ref in Array(ref.workspace.screens.dropFirst(ref.index + 1)) }),
            ("screen.closeToLeft", { ref in Array(ref.workspace.screens.prefix(ref.index)).filter { !$0.pinned } }),
        ]
        for (id, pick) in closeVariants {
            registry.bind(id, invoke: { invocation in
                guard let ref = ctx.screen(invocation) else { return }
                let screens = pick(ref)
                guard !screens.isEmpty else { return ctx.refuse(ScreenStrings.noOtherScreens) }
                ScreenCommands.close(screens, in: ref.workspace, daemon: ref.daemon, services: ctx.services)
            })
        }
        registry.bind("screen.reopenClosed", invoke: { _ in
            guard let record = ctx.services.closedScreens.popLatest(isLive: { ctx.services.workspace(id: $0) != nil })
                ?? ctx.refuse(ScreenStrings.noClosedScreen) else { return }
            reopen(record, ctx)
        })
    }

    /// Recreates a closed screen with its metadata at its old position (also
    /// from history lists). False when its workspace is gone.
    @discardableResult
    static func reopen(_ record: ClosedScreenHistory.Record, _ ctx: AppActionContext) -> Bool {
        guard let workspace = ctx.services.workspace(id: record.workspaceID) else { return false }
        let daemon = ctx.services.machines.daemons.first { $0.store.workspaces.contains { $0 === workspace } } ?? ctx.services.activeDaemon
        let content = ctx.window(showing: workspace.id).flatMap(\.content)
        let spec = workspace.resourceID != nil ? record.spec : ScreenSpec()
        ScreenCommands.create(in: workspace, daemon: daemon, content: content, spec: spec)
        return true
    }

    private static func bindNavigation(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("screen.next", invoke: { invocation in adjacent(1, invocation, ctx) })
        registry.bind("screen.previous", invoke: { invocation in adjacent(-1, invocation, ctx) })
        registry.bind("screen.select", invoke: { invocation in
            guard let content = ctx.content(invocation) else { return }
            guard let number = invocation["index"]?.intValue ?? ctx.refuse(RefusalStrings.indexRequired) else { return }
            let screens = content.layoutModel.screens
            // 9 is the last screen, like Chrome's Cmd-9.
            let index = number == 9 ? screens.count - 1 : number - 1
            guard screens.indices.contains(index) else { return ctx.refuse(RefusalStrings.screenCount(screens.count)) }
            ScreenCommands.select(screens[index].id, in: content)
        })
        registry.bind("screen.selectLast", invoke: { invocation in
            guard let content = ctx.content(invocation) else { return }
            guard let last = content.layoutModel.screens.last ?? ctx.refuse(RefusalStrings.workspaceHasNoScreen) else { return }
            ScreenCommands.select(last.id, in: content)
        })
    }

    private static func adjacent(_ offset: Int, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let content = ctx.content(invocation) else { return }
        guard content.layoutModel.screens.count > 1 else { return ctx.refuse(RefusalStrings.workspaceHasOneScreen) }
        ScreenCommands.selectAdjacent(offset, in: content)
    }

    private static func bindMoves(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        for (id, offset) in [("screen.moveLeft", -1), ("screen.moveRight", 1)] as [(ActionID, Int)] {
            registry.bind(id, invoke: { invocation in
                guard let ref = ctx.screen(invocation), ctx.requireScreenState(ref.screen) else { return }
                let target = ref.index + offset
                guard ref.workspace.screens.indices.contains(target) else { return ctx.refuse(ScreenStrings.screenAtEdge) }
                ScreenCommands.move(ref.screen, to: target, daemon: ref.daemon)
            })
        }
        // The protocol/2 state resources move a screen only within its
        // workspace; moving one to another or a new workspace waits for a
        // daemon operation (plans/cmux-next/state-ownership.md).
        registry.bindUnavailable(["screen.moveToWorkspace", "screen.moveToNewWorkspace", "screen.moveToNewWindow"],
                                 ActionFailure.needsDaemonCapability("screen-workspace-move"))
    }

    static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
