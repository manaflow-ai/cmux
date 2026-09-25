import CmuxCloud
import AppKit
import Foundation
import CmuxSettings

/// Closure bundle handed to rows. Bound above the lazy boundary; rows never
/// see the store. All verbs go through `CloudVMActionLauncher` so this panel,
/// the ＋ menu, the palette, and the CLI share one mutation path.
struct MachineRowActions {
    let openShell: @MainActor (String) -> Void
    let openDesktop: @MainActor (String) -> Void
    let runCommand: @MainActor (String, [String]) -> Void
    let confirmDelete: @MainActor (String) -> Void
    let promptRename: @MainActor (String, String?) -> Void
    /// Grow the machine through the shared `cmux vm resize` command.
    let resizeDisk: @MainActor (String, Int) -> Void
    var resizeCPU: @MainActor (String, Int) -> Void = { _, _ in }
    var resizeMemory: @MainActor (String, Int) -> Void = { _, _ in }
    /// Plan-advertised targets. Empty means use the provider's conservative ladder.
    var resizeCPUOptions: [Int] = []
    var resizeMemoryOptionsGiB: [Int] = []
    /// A locked (free-window-expired) machine routes here instead of a doomed
    /// connect; the backend enforces the same boundary with 402s.
    let promptUpgrade: @MainActor () -> Void
    /// Persists a pin and returns the authoritative fleet order/render state.
    /// Nil means the action was not accepted (for example, after sign-out).
    var setPinned: @MainActor (String, Bool) -> [MachineSnapshot]? = { _, _ in nil }
    /// Account-bound local ordering; no machine command or connection mutation.
    var ordering: CloudMachineOrderingActions?
    /// Verbs of the pending rows (creates still running or failed).
    var create: MachineCreateRowActions = .inert

    static func bound(
        onWillMutate: @escaping @MainActor (String) -> Void = { _ in },
        onDidMutate: @escaping @MainActor () -> Void
    ) -> MachineRowActions {
        MachineRowActions(
            openShell: { id in
                onWillMutate(String(format: String(localized: "machines.operation.openShell", defaultValue: "Opening %@\u{2026}"), id))
                if !launch(arguments: ["vm", "shell", id], onDidMutate: onDidMutate) {
                    onDidMutate()
                }
            },
            openDesktop: { id in
                onWillMutate(String(format: String(localized: "machines.operation.openDesktop", defaultValue: "Opening %@\u{2019}s desktop\u{2026}"), id))
                if !launch(arguments: ["vm", "desktop", id], onDidMutate: onDidMutate) {
                    onDidMutate()
                }
            },
            runCommand: { id, verb in
                onWillMutate(operationLabel(verb: verb, id: id))
                let result = resultPresentation(verb: verb)
                if !launch(
                    arguments: verb + [id],
                    successTitle: result.title,
                    presentOutputOnSuccess: result.presentsOutput,
                    onDidMutate: onDidMutate
                ) {
                    onDidMutate()
                }
            },
            confirmDelete: { id in
                presentDeleteConfirmation(id: id, onWillMutate: onWillMutate, onDidMutate: onDidMutate)
            },
            promptRename: { id, currentLabel in
                presentRenamePrompt(id: id, currentLabel: currentLabel, onWillMutate: onWillMutate, onDidMutate: onDidMutate)
            },
            resizeDisk: { id, gib in
                onWillMutate(String(format: String(localized: "machines.operation.resizeDisk", defaultValue: "Increasing %@ disk to %d GiB…"), id, gib))
                if !launch(arguments: ["vm", "resize", id, "--disk", "\(gib)G"], onDidMutate: onDidMutate) {
                    onDidMutate()
                }
            },
            resizeCPU: { id, cpu in
                onWillMutate(String(format: String(localized: "machines.operation.resize", defaultValue: "Resizing %@…"), id))
                if !launch(arguments: ["vm", "resize", id, "--cpu", "\(cpu)"], onDidMutate: onDidMutate) { onDidMutate() }
            },
            resizeMemory: { id, gib in
                onWillMutate(String(format: String(localized: "machines.operation.resize", defaultValue: "Resizing %@…"), id))
                if !launch(arguments: ["vm", "resize", id, "--memory", "\(gib)G"], onDidMutate: onDidMutate) { onDidMutate() }
            },
            promptUpgrade: {
                ProUpgradePresenter.present(source: .machinesPanelMachineAction)
            }
        )
    }

    /// What to show when a row verb finishes. Status and Checkpoint are
    /// read-only reports, so their output is the whole point and opens in the
    /// house result sheet; Fork attaches the new machine as a workspace, so a
    /// sheet would only get in the way. Same policy as the palette's
    /// `CurrentCloudVMCommand`.
    private static func resultPresentation(verb: [String]) -> (title: String?, presentsOutput: Bool) {
        if verb.contains("status") {
            return (String(localized: "command.cloudVM.status.result.title", defaultValue: "Cloud VM Status"), true)
        }
        if verb.contains("snapshot") {
            return (String(localized: "command.cloudVM.snapshot.result.title", defaultValue: "Cloud VM Checkpoint"), true)
        }
        if verb.contains("resize") {
            return (String(localized: "command.cloudVM.resize.result.title", defaultValue: "Cloud VM Resized"), true)
        }
        if verb.contains("fork") {
            return (String(localized: "command.cloudVM.fork.result.title", defaultValue: "Cloud VM Forked"), false)
        }
        return (nil, false)
    }

    private static func operationLabel(verb: [String], id: String) -> String {
        let format: String
        if verb.contains("snapshot") {
            format = String(localized: "machines.operation.checkpoint", defaultValue: "Checkpointing %@\u{2026}")
        } else if verb.contains("resize") {
            format = String(localized: "machines.operation.resize", defaultValue: "Resizing %@\u{2026}")
        } else if verb.contains("fork") {
            format = String(localized: "machines.operation.fork", defaultValue: "Forking %@\u{2026}")
        } else if verb.contains("status") {
            format = String(localized: "machines.operation.status", defaultValue: "Checking %@\u{2026}")
        } else if verb.contains("rename") {
            format = String(localized: "machines.operation.rename", defaultValue: "Renaming %@\u{2026}")
        } else if verb.contains("rm") {
            format = String(localized: "machines.operation.delete", defaultValue: "Deleting %@\u{2026}")
        } else {
            format = String(localized: "machines.operation.generic", defaultValue: "Working on %@\u{2026}")
        }
        return String(format: format, id)
    }

    @MainActor
    @discardableResult
    /// `arguments` is the `cmux vm new …` invocation the New Machine sheet
    /// built (kind, size, name). Failures come back through `onCompletion`
    /// so the sheet can show them inline instead of a detached alert.
    static func openNewMachine(
        arguments: [String] = ["vm", "new"],
        onOutput: (@MainActor (String) -> Void)? = nil,
        onCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil,
        onCancellationReady: ((CloudVMActionLauncher.CancellationHandle) -> Void)? = nil
    ) -> Bool {
        // `vm new` mints a fresh machine with an ephemeral home and
        // attaches it; the base slot stays reachable via the ＋ menu's Open Base.
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            arguments: arguments,
            presentsFailureAlert: false,
            onCancellationReady: onCancellationReady,
            onOutput: onOutput,
            onCompletion: onCompletion
        )
    }

    @MainActor
    private static func launch(
        arguments: [String],
        successTitle: String? = nil,
        presentOutputOnSuccess: Bool = false,
        onCancellationReady: ((CloudVMActionLauncher.CancellationHandle) -> Void)? = nil,
        onSuccess: (@MainActor () -> Void)? = nil,
        onDidMutate: @escaping @MainActor () -> Void
    ) -> Bool {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            arguments: arguments,
            successTitle: successTitle,
            presentOutputOnSuccess: presentOutputOnSuccess,
            onCancellationReady: onCancellationReady,
            onCompletion: { completion in
                if completion.terminationStatus == 0 {
                    onSuccess?()
                }
                onDidMutate()
            }
        )
    }

    @MainActor
    private static func presentRenamePrompt(
        id: String,
        currentLabel: String?,
        onWillMutate: @escaping @MainActor (String) -> Void = { _ in },
        onDidMutate: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let format = String(localized: "machines.rename.title", defaultValue: "Rename \u{201C}%@\u{201D}")
        alert.messageText = String(format: format, id)
        alert.informativeText = String(
            localized: "machines.rename.message",
            defaultValue: "The label is display-only. The machine keeps its name as its address."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentLabel ?? ""
        field.placeholderString = String(localized: "machines.rename.placeholder", defaultValue: "Label")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "machines.rename.confirm", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var arguments = ["vm", "rename", id]
            if label.isEmpty {
                arguments.append("--clear")
            } else {
                arguments.append(label)
            }
            onWillMutate(operationLabel(verb: ["rename"], id: id))
            if !launch(arguments: arguments, onDidMutate: onDidMutate) {
                onDidMutate()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @MainActor
    private static func presentDeleteConfirmation(
        id: String,
        onWillMutate: @escaping @MainActor (String) -> Void = { _ in },
        onDidMutate: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let format = String(
            localized: "machines.delete.title",
            defaultValue: "Delete machine “%@”?"
        )
        alert.messageText = String(format: format, id)
        alert.informativeText = String(
            localized: "machines.delete.message",
            defaultValue: "This permanently deletes the machine and everything stored on it. This cannot be undone."
        )
        alert.addButton(withTitle: String(localized: "machines.delete.confirm", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onWillMutate(operationLabel(verb: ["rm"], id: id))
            if !launch(
                arguments: ["vm", "rm", id],
                onSuccess: {
                    // The machine is gone; its workspaces would only sit there "Connected".
                    AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: id)
                },
                onDidMutate: onDidMutate
            ) {
                onDidMutate()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}
