import AppKit
import CmuxNextActions
import CmuxNextTerminal

/// The TextBox composer's actions (inventory row 23) on the targeted or focused terminal: Toggle
/// TextBox, Focus TextBox (back and forth between the box and the terminal), Cycle TextBox Submit
/// Action and Attach File to TextBox, and Insert Path (its file panel, the paths typed into the terminal).
/// The palette, the keys, the box's own Shift-Tab and buttons, `cmux action run` and MCP all run these.
enum TextBoxHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("palette.terminalToggleTextBoxInput", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            textBox(of: entry, ctx).toggle(focus: invocation.allowsViewChange)
        })
        ActionTargetTitles.setPaletteState("palette.terminalToggleTextBoxInput", in: registry) {
            if case .terminal(let entry)? = ctx.services.windows.active?.focusedPane?.currentContent { entry.textBox?.model.isVisible == true } else { false }
        }
        registry.bind("focusTextBoxInput", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            let box = textBox(of: entry, ctx)
            if box.hasKeyboard { return box.focusTerminal() }
            box.show(focus: invocation.allowsViewChange)
        })
        registry.bind("cycleTextBoxSubmitAction", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            textBox(of: entry, ctx).model.cycle()
        })
        registry.bind("attachTextBoxFile", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            let box = textBox(of: entry, ctx), focus = invocation.allowsViewChange
            box.show(focus: focus)
            let window = entry.session.view.window
            registry.track(Task { @MainActor in
                let paths = await TerminalFilePicker.choose(NSOpenPanel(), title: TextBoxStrings.addFilesPanelTitle, prompt: TextBoxStrings.addFilesPanelPrompt, in: window)
                box.insert(paths: paths)
                if focus, !paths.isEmpty { box.show(focus: true) }
                return nil
            })
        })
        bindInsertPath(registry, ctx)
    }

    /// Insert Path (⌃⌘I): the made-ahead panel's paths (local terminals) or a `path` argument's, typed as a drop is.
    private static func bindInsertPath(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bindEffect("insertPath", effect: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return .done }
            guard tab.kind == .pty else { return .refused(RefusalStrings.notATerminal) }
            let surface = tab.surface, daemon = ctx.services.daemon(for: pane), given = invocation["path"]?.stringValue.flatMap { $0.isEmpty ? nil : [$0] }
            guard given != nil || daemon.isLocal else { return .refused(FindInDirectoryStrings.localOnly) }
            let panel = given == nil ? ctx.services.openPanel.panel() : nil, window = ctx.activeWindow?.window
            // action-wait-allow: the person picks in the system's open panel (its own process); the shell echoes the paths
            return .waiting(.externalProcess) {
                let paths = if let panel { await TerminalFilePicker.choose(panel, prompt: FindInDirectoryStrings.insertPath, in: window) } else { given ?? [] }
                guard let text = TerminalFilePicker.insertText(for: paths) else { return nil }
                return await daemon.failure("send") { try await $0.send(surface, text: text, paste: true) }
            }
        })
    }

    /// `entry`'s TextBox, made (hidden) the first time. Its Shift-Tab and buttons run the
    /// registry's actions on the pane that shows `entry`, in the TextBox's context.
    static func textBox(of entry: TerminalEntry, _ ctx: AppActionContext) -> TextBoxController {
        if let box = entry.textBox { return box }
        let services = ctx.services
        let box = TextBoxController(session: entry.session, perform: { [weak entry] command in
            guard let entry, let pane = pane(showing: entry, services) else { return }
            let context = services.registry.context.subtracting(ActionContext.focusBits).union([.terminalFocused, .textBoxFocused])
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), keyContext: context).onMachine(pane.daemon.machineID)
            _ = services.registry.perform(ActionID(rawValue: command.rawValue), invocation: invocation)
        })
        entry.textBox = box
        return box
    }

    private static func pane(showing entry: TerminalEntry, _ services: AppServices) -> PaneController? {
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                if case .terminal(let shown)? = pane.currentContent, shown === entry { return pane }
            }
        }
        return nil
    }
}
