import AppKit
import CmuxNextActions
import CmuxNextTerminal
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The TextBox composer's actions (inventory row 23) on the targeted or focused terminal: Toggle
/// TextBox, Focus TextBox (back and forth between the box and the terminal), Cycle TextBox Submit
/// Action and Attach File to TextBox. The palette, the keys, the box's own Shift-Tab and buttons,
/// `cmux action run` and MCP all run these.
enum TextBoxHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("palette.terminalToggleTextBoxInput", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            textBox(of: entry, ctx).toggle(focus: invocation.allowsViewChange)
        })
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
            // The person's pick is awaited off main; the files go into the box in the run's completion.
            registry.trackWork(owner: "TextBoxHandlers.attach", on: ctx.services.mainWork) {
                await chooseFiles(in: window)
            } then: { result in
                let paths = (try? result.get()) ?? []
                box.insert(paths: paths)
                if focus, !paths.isEmpty { box.show(focus: true) }
                return nil
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
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey))
            invocation.keyContext = services.registry.context.subtracting(ActionContext.focusBits)
                .union([.terminalFocused, .textBoxFocused])
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

    /// Add Files: a multi-selection file panel, a sheet on `window` when there is one; no paths on cancel.
    private static func chooseFiles(in window: NSWindow?) async -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = TextBoxStrings.addFilesPanelTitle
        panel.prompt = TextBoxStrings.addFilesPanelPrompt
        // A panel that drops its reply was cancelled.
        let response = (try? await withOnceContinuation { (done: OnceContinuation<NSApplication.ModalResponse, OnceContinuationError>) in
            if let window {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else {
                panel.begin { done.resume(returning: $0) }
            }
        }) ?? .cancel
        return response == .OK ? panel.urls.map(\.path) : []
    }
}
