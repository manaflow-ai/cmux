import AppKit
import Foundation

/// Closure bundle handed to Cloud outline rows for the nodes below a machine.
/// Bound once above the outline (never a store below it). Every verb routes
/// through the app-side `CloudTreeServicing` — the same path the CLI's
/// `cmux vm open` uses — and degrades to the CLI-launch machine verbs when the
/// service is not wired.
struct CloudTreeNodeActions {
    let openTerminal: @MainActor (_ machineID: String, _ terminalID: String, _ placement: CloudTreePlacement) -> Void
    let newTerminal: @MainActor (_ machineID: String, _ workspaceID: String?) -> Void
    let openWorkspace: @MainActor (_ machineID: String, _ workspace: CloudTreeWorkspace) -> Void
    let openDesktop: @MainActor (_ machineID: String) -> Void
    let openPort: @MainActor (_ machineID: String, _ port: Int) -> Void
    let copyToPasteboard: @MainActor (_ text: String) -> Void
    let refresh: @MainActor () -> Void

    @MainActor
    static func bound(
        machineActions: MachineRowActions,
        service: @escaping @MainActor () -> (any CloudTreeServicing)?,
        onWillMutate: @escaping @MainActor (String) -> Void,
        onDidMutate: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void,
        refresh: @escaping @MainActor () -> Void
    ) -> CloudTreeNodeActions {
        func run(_ label: String, _ operation: @escaping @MainActor (any CloudTreeServicing) async throws -> Void, fallback: @escaping @MainActor () -> Void) {
            guard let service = service() else {
                fallback()
                return
            }
            onWillMutate(label)
            Task { @MainActor in
                do {
                    try await operation(service)
                } catch {
                    onFailure(String(describing: error))
                }
                onDidMutate()
            }
        }
        return CloudTreeNodeActions(
            openTerminal: { machineID, terminalID, placement in
                run(
                    String(format: String(localized: "cloudTree.operation.openTerminal", defaultValue: "Opening terminal on %@\u{2026}"), machineID),
                    { _ = try await $0.openTerminal(machineID: machineID, terminalID: terminalID, workspaceID: nil, placement: placement, focus: true) },
                    // Without the service the closest thing is the machine's shell.
                    fallback: { machineActions.openShell(machineID) }
                )
            },
            newTerminal: { machineID, workspaceID in
                run(
                    String(format: String(localized: "cloudTree.operation.newTerminal", defaultValue: "Starting a terminal on %@\u{2026}"), machineID),
                    { _ = try await $0.newTerminal(machineID: machineID, workspaceID: workspaceID, command: nil, cwd: nil, name: nil, open: true) },
                    fallback: { machineActions.openShell(machineID) }
                )
            },
            openWorkspace: { machineID, workspace in
                // The workspace's focused terminal, else its first, else a fresh one.
                let terminal = workspace.terminals.first
                if let terminal {
                    run(
                        String(format: String(localized: "cloudTree.operation.openTerminal", defaultValue: "Opening terminal on %@\u{2026}"), machineID),
                        { _ = try await $0.openTerminal(machineID: machineID, terminalID: terminal.id, workspaceID: nil, placement: .split, focus: true) },
                        fallback: { machineActions.openShell(machineID) }
                    )
                } else {
                    run(
                        String(format: String(localized: "cloudTree.operation.newTerminal", defaultValue: "Starting a terminal on %@\u{2026}"), machineID),
                        { _ = try await $0.newTerminal(machineID: machineID, workspaceID: workspace.id, command: nil, cwd: nil, name: nil, open: true) },
                        fallback: { machineActions.openShell(machineID) }
                    )
                }
            },
            openDesktop: { machineID in
                run(
                    String(format: String(localized: "machines.operation.openDesktop", defaultValue: "Opening %@\u{2019}s desktop\u{2026}"), machineID),
                    { _ = try await $0.openDesktop(machineID: machineID, workspaceID: nil, focus: true) },
                    fallback: { machineActions.openDesktop(machineID) }
                )
            },
            openPort: { machineID, port in
                run(
                    String(format: String(localized: "cloudTree.operation.openPort", defaultValue: "Opening port %2$d on %1$@\u{2026}"), machineID, port),
                    { _ = try await $0.openPort(machineID: machineID, port: port, workspaceID: nil) },
                    fallback: { machineActions.runCommand(machineID, ["vm", "open", machineID, String(port)]) }
                )
            },
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            refresh: refresh
        )
    }
}
