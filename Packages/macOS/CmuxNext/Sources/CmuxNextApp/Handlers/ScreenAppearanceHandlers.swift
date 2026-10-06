import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// Screen name, color, icon, and pin actions.
enum ScreenAppearanceHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("screen.rename", invoke: { invocation in
            guard let ref = ctx.screen(invocation) else { return }
            if let name = invocation["name"]?.stringValue {
                return ScreenCommands.rename(ref.screen, to: name, daemon: ref.daemon)
            }
            // Inline in the screen bar when it shows the screen, else a prompt.
            if ref.content?.screenBar.beginRename(ref.screen) == true { return }
            guard let window = ctx.services.windows.active?.window ?? ctx.refuse(RefusalStrings.noWindowForRename) else { return }
            RenamePrompt.run(title: HandlerStrings.renameScreenTitle, initial: ref.screen.name ?? "", in: window) { name in
                ScreenCommands.rename(ref.screen, to: name, daemon: ref.daemon)
            }
        })
        registry.bind("screen.clearName", invoke: { invocation in
            guard let ref = ctx.screen(invocation) else { return }
            ScreenCommands.rename(ref.screen, to: "", daemon: ref.daemon)
        })
        registry.bind("screen.setColor", invoke: { invocation in
            guard let ref = metadataTarget(invocation, ctx) else { return }
            guard let raw = invocation["color"]?.stringValue, GroupColor(rawValue: raw) != nil
                ?? ctx.refuse(RefusalStrings.colorArgumentRequired) else { return }
            ScreenCommands.setColor(ref.screen, raw, daemon: ref.daemon)
        })
        for color in GroupColor.allCases {
            registry.bind(ActionID(rawValue: "screen.color.\(color.rawValue)"), invoke: { invocation in
                guard let ref = metadataTarget(invocation, ctx) else { return }
                ScreenCommands.setColor(ref.screen, color.rawValue, daemon: ref.daemon)
            })
        }
        registry.bind("screen.clearColor", invoke: { invocation in
            guard let ref = metadataTarget(invocation, ctx) else { return }
            ScreenCommands.setColor(ref.screen, nil, daemon: ref.daemon)
        })
        registry.bind("screen.setIcon", invoke: { invocation in
            guard let ref = metadataTarget(invocation, ctx) else { return }
            if let icon = invocation["icon"]?.stringValue.flatMap(ScreenHandlers.nonEmpty) {
                return ScreenCommands.setIcon(ref.screen, icon, daemon: ref.daemon)
            }
            guard let anchor = ctx.services.iconPicker.activeWindowAnchor() ?? ctx.refuse(ScreenStrings.iconArgumentRequired) else { return }
            ctx.services.iconPicker.pick(current: ref.screen.icon, target: "screen:\(ref.screen.id)", at: anchor) { result in
                switch result {
                case .set(let icon): ScreenCommands.setIcon(ref.screen, icon, daemon: ref.daemon)
                case .clear: ScreenCommands.setIcon(ref.screen, nil, daemon: ref.daemon)
                case .cancel: break
                }
            }
        })
        registry.bind("screen.clearIcon", invoke: { invocation in
            guard let ref = metadataTarget(invocation, ctx) else { return }
            ScreenCommands.setIcon(ref.screen, nil, daemon: ref.daemon)
        })
        registry.bind("screen.togglePin", invoke: { invocation in
            guard let ref = metadataTarget(invocation, ctx) else { return }
            ScreenCommands.setPinned(ref.screen, !ref.screen.pinned, daemon: ref.daemon)
        })
    }

    /// The targeted screen on a daemon with `screen-metadata-v1`.
    private static func metadataTarget(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> ScreenRef? {
        guard let ref = ctx.screen(invocation), ctx.require(DaemonCapabilities.shared.screenMetadata, on: ref.daemon) else { return nil }
        return ref
    }
}
