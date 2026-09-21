import AppKit
import Foundation

/// The New Machine sheet's create, run inside the app instead of through a
/// `cmux vm new` subprocess: one `POST /api/vm` that leaves in the click's own
/// turn, the link dialed from that response, and the machine's terminal
/// projected over the reserved loading card through the same catalog path
/// `surface.new_terminal` uses. It speaks the coordinator's existing launch
/// contract (argv in, progress and completion out), so the pending row, retry,
/// cancel and tombstone cleanup are unchanged; `cmux vm new` keeps the CLI path.
@MainActor
enum InProcessMachineCreateLauncher {
    struct Invocation: Equatable, Sendable {
        enum Verb: Equatable, Sendable {
            case create(kind: VMMachineKind?, memoryMb: Int?, displayName: String?)
            case open(machineID: String)
        }
        let verb: Verb
        let workspaceID: UUID
        let focus: Bool
        let windowID: UUID?
    }

    /// What the deferred attachment names as its command; the loading card never runs it.
    nonisolated static let placeholderCommand = "sleep 60"

    /// The create the sheet builds (`vm new [--desktop|--base] [--size N] [--name L]
    /// --focus B --workspace U [--window W]`) and the coordinator's retry
    /// (`vm open <id> --workspace U --focus B`). Anything else (Base setup, a bare
    /// `vm new`, an image override, an unknown flag) stays on the bundled CLI.
    nonisolated static func parse(arguments: [String]) -> Invocation? {
        var tokens = arguments[...]
        guard tokens.count >= 2, tokens.removeFirst() == "vm" else { return nil }
        let verb = tokens.removeFirst()
        var machineID: String?
        if verb == "open" {
            guard let id = tokens.popFirst(), !id.hasPrefix("-"), !id.isEmpty else { return nil }
            machineID = id
        } else if verb != "new" {
            return nil
        }
        var kind: VMMachineKind?
        var memoryMb: Int?
        var displayName: String?
        var focus = true
        var workspaceID: UUID?
        var windowID: UUID?
        while let token = tokens.popFirst() {
            switch token {
            case "--desktop":
                kind = .desktop
            case "--base", "--no-desktop":
                kind = .base
            case "--size":
                guard let raw = tokens.popFirst(), let value = Int(raw) else { return nil }
                memoryMb = value
            case "--name":
                guard let raw = tokens.popFirst() else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                displayName = trimmed.isEmpty ? nil : trimmed
            case "--focus":
                guard let raw = tokens.popFirst() else { return nil }
                switch raw.lowercased() {
                case "true", "1", "yes": focus = true
                case "false", "0", "no": focus = false
                default: return nil
                }
            case "--workspace":
                guard let raw = tokens.popFirst(), let id = UUID(uuidString: raw) else { return nil }
                workspaceID = id
            case "--window":
                guard let raw = tokens.popFirst(), let id = UUID(uuidString: raw) else { return nil }
                windowID = id
            default:
                return nil
            }
        }
        guard let workspaceID else { return nil }
        if let machineID {
            return Invocation(verb: .open(machineID: machineID), workspaceID: workspaceID, focus: focus, windowID: windowID)
        }
        return Invocation(
            verb: .create(kind: kind, memoryMb: memoryMb, displayName: displayName),
            workspaceID: workspaceID, focus: focus, windowID: windowID
        )
    }

    /// One key per operation: a retry of the same operation resends it, so the backend
    /// joins the in-flight create or replays the finished one; no on-disk store.
    nonisolated static func idempotencyKey(operationID: UUID) -> String {
        "app-" + operationID.uuidString.lowercased()
    }

    /// Every collaborator behind one seam, so the flow is verifiable without a
    /// backend, a machine or a window. All closures run on the main actor.
    struct Dependencies {
        var create: @MainActor (Invocation, String) async throws -> VMCreateResult
        var status: @MainActor (String) async throws -> VMSummary
        var cachedAttach: @MainActor (String) -> VMCreateAttach?
        var recordCreatedMachine: @MainActor (VMSummary, VMCreateAttach?) async -> Void
        var prepareLoadingPane: @MainActor (UUID, Bool) throws -> UUID
        var bind: @MainActor (UUID, String, String?) -> Void
        var connect: @MainActor (String, VMCreateAttach?) async throws -> Void
        var newTerminal: @MainActor (String, UUID, Bool) async throws -> String?
        var isWorkspaceSelected: @MainActor (UUID) -> Bool
    }

    /// The production collaborators. `request` is the create already in flight (nil for
    /// an open), started by ``start`` before this turn's workspace mount ran.
    static func live(request: Task<VMCreateResult, Error>?, registry: CmuxTuiSurfaceProviderRegistry) -> Dependencies {
        // Captured before the create completes, so a late receipt cannot enter another account.
        let scope = registry.creationScope
        let generatedTitle = String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
        return Dependencies(
            create: { _, _ in
                guard let request else { throw VMClientError.notSignedIn }
                return try await withTaskCancellationHandler {
                    try await request.value
                } onCancel: {
                    request.cancel()
                }
            },
            status: { id in
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                return try await client.status(id: id)
            },
            cachedAttach: { id in registry.cachedCreateAttach(machineID: id) },
            recordCreatedMachine: { summary, attach in
                _ = await registry.recordCreatedMachine(summary, attach: attach, scope: scope)
            },
            prepareLoadingPane: { workspaceID, focus in
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else {
                    throw TerminalController.CloudVMTerminalAttachmentError.workspaceNotFound
                }
                return try TerminalController.shared.replaceCloudVMLoadingPane(
                    workspaceID: workspaceID, in: tabManager, command: placeholderCommand, deferTerminal: true, focus: focus
                ).panelID
            },
            bind: { workspaceID, machineID, remoteWorkspaceID in
                SurfaceCatalog.shared.bindCloudWorkspace(
                    localWorkspaceID: workspaceID, machine: .cloud(machineID), remoteWorkspaceID: remoteWorkspaceID,
                    isBase: false, generatedTitle: generatedTitle
                )
            },
            connect: { machineID, attach in
                if let attach {
                    try await registry.connectFreshMachine(machineID: machineID, attach: attach)
                } else {
                    // No route in the create response: the existing link path asks the
                    // control plane once, exactly as the CLI's open does today.
                    _ = try await registry.linkSocketPath(machineID: machineID)
                }
            },
            newTerminal: { machineID, workspaceID, focus in
                let payload = try await TerminalController.surfaceNewTerminal(
                    machine: .cloud(machineID), command: nil, cwd: nil, name: nil, remoteWorkspaceID: nil,
                    destination: .workspace(id: workspaceID, placement: .tab), focus: focus
                )
                return payload["remote_workspace_id"] as? String
            },
            isWorkspaceSelected: { workspaceID in
                guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else { return false }
                return manager.selectedTabId == workspaceID && manager.window?.isKeyWindow != false
            }
        )
    }

    /// The create as a CLI-shaped transcript: the receipt line as soon as the backend
    /// names the machine, `workspace=<uuid>` once its terminal is in the workspace.
    /// Never throws; cancellation is a completion too, with the machine id the
    /// coordinator's tombstone needs to destroy what was created.
    static func run(
        _ invocation: Invocation,
        operationID: UUID,
        dependencies: Dependencies,
        onOutput: @escaping @MainActor (String) -> Void
    ) async -> CloudVMActionLauncher.Completion {
        var output = ""
        var machineID: String?
        let startedAt = Date()
        do {
            var attach: VMCreateAttach?
            var summary: VMSummary?
            switch invocation.verb {
            case .create:
                let created = try await dependencies.create(invocation, idempotencyKey(operationID: operationID))
                machineID = created.summary.id
                summary = created.summary
                attach = created.attach
                let receipt = "OK machine=\(created.summary.id)\n"
                output += receipt
                onOutput(receipt)
#if DEBUG
                cmuxDebugLog(
                    "cloud.create.machine operation=\(operationID.uuidString) machine=\(created.summary.id) " +
                    "attach=\(created.attach != nil ? 1 : 0) elapsed=\(Date().timeIntervalSince(startedAt))"
                )
#endif
                await dependencies.recordCreatedMachine(created.summary, created.attach)
            case .open(let id):
                machineID = id
                attach = dependencies.cachedAttach(id)
            }
            guard let machineID else { throw VMClientError.malformedResponse("The create response did not name a machine.") }
            try Task.checkCancellation()
            // Focus inside the workspace the person is already looking at is not
            // stealing; focus that would switch them to another workspace is.
            let focus = invocation.focus || dependencies.isWorkspaceSelected(invocation.workspaceID)
            _ = try dependencies.prepareLoadingPane(invocation.workspaceID, focus)
            dependencies.bind(invocation.workspaceID, machineID, nil)
            if attach == nil, summary?.addressIPv4 == nil, summary?.addressIPv6 == nil {
                // Older control plane: the create response named no address. One status
                // read supplies it and registers the provider the link needs.
                let refreshed = try await dependencies.status(machineID)
                try Task.checkCancellation()
                await dependencies.recordCreatedMachine(refreshed, nil)
            }
            try Task.checkCancellation()
            try await dependencies.connect(machineID, attach)
            try Task.checkCancellation()
#if DEBUG
            cmuxDebugLog("cloud.create.linked operation=\(operationID.uuidString) machine=\(machineID) elapsed=\(Date().timeIntervalSince(startedAt))")
#endif
            let remoteWorkspaceID = try await dependencies.newTerminal(machineID, invocation.workspaceID, focus)
            if let remoteWorkspaceID, !remoteWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dependencies.bind(invocation.workspaceID, machineID, remoteWorkspaceID)
            }
            output += "workspace=\(invocation.workspaceID.uuidString)\n"
#if DEBUG
            cmuxDebugLog("cloud.create.terminal operation=\(operationID.uuidString) machine=\(machineID) elapsed=\(Date().timeIntervalSince(startedAt))")
#endif
            return CloudVMActionLauncher.Completion(
                terminationStatus: 0, output: output, workspaceId: invocation.workspaceID, machineId: machineID
            )
        } catch {
            if isCancellation(error) {
                return CloudVMActionLauncher.Completion(
                    terminationStatus: 1, output: output, workspaceId: nil, machineId: machineID, wasCancelled: true
                )
            }
#if DEBUG
            cmuxDebugLog("cloud.create.failed operation=\(operationID.uuidString) machine=\(machineID ?? "none") error=\(CloudMachineLink.errorText(error))")
#endif
            return CloudVMActionLauncher.Completion(
                terminationStatus: 1, output: output + CloudMachineLink.errorText(error) + "\n",
                workspaceId: nil, machineId: machineID
            )
        }
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// The coordinator's launch shape. Returns false, after opening the shared sign-in
    /// screen, when nothing is signed in: the same rule as every native launcher
    /// entrypoint, so a signed-out click never creates a machine.
    @discardableResult
    static func start(
        arguments: [String],
        operationID: UUID,
        onOutput: (@MainActor (String) -> Void)? = nil,
        onCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil,
        onCancellationReady: ((CloudVMActionLauncher.CancellationHandle) -> Void)? = nil
    ) -> Bool {
        guard let invocation = parse(arguments: arguments) else { return false }
        let accountFlow = AppDelegate.shared?.auth?.accountFlow
        let authState = CloudVMPanelAuthState.resolve(
            isAuthenticated: accountFlow?.isAuthenticated == true,
            isWorkingOnAuth: accountFlow?.isWorkingOnAuth == true
        )
        guard authState.allowsAuthenticatedOperation, let client = VMClient.shared else {
            _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
                debugSource: "cloudVM.auth"
            )
            return false
        }
        let context = AppDelegate.shared?.cloudOperations?.begin(.create)
        // The request leaves this turn: a detached task hops to the client actor now,
        // before the reserved workspace mounts and the sidebar rebuilds behind it.
        let request: Task<VMCreateResult, Error>?
        if case .create(let kind, let memoryMb, let displayName) = invocation.verb {
            let resolvedKind = kind ?? NewMachineModel.machineKind
            let key = idempotencyKey(operationID: operationID)
            request = Task.detached(priority: .userInitiated) {
                try await CloudOperationContext.withCurrent(context) {
                    try await client.createMachine(
                        kind: resolvedKind, memoryMb: memoryMb, displayName: displayName, idempotencyKey: key
                    )
                }
            }
        } else {
            request = nil
        }
        let dependencies = live(request: request, registry: CmuxTuiSurfaceProviderRegistry.shared)
        let task = Task { @MainActor in
            let completion = await CloudOperationContext.withCurrent(context) {
                await run(invocation, operationID: operationID, dependencies: dependencies, onOutput: { chunk in onOutput?(chunk) })
            }
            if let context {
                let diagnosticError: Error? = completion.wasCancelled ? CancellationError()
                    : completion.succeeded ? nil : CloudMachineLink.LinkError.exited(status: completion.terminationStatus, output: "")
                await context.recorder.finish(context, error: diagnosticError)
            }
            onCompletion?(completion)
        }
        onCancellationReady?(CloudVMActionLauncher.CancellationHandle {
            request?.cancel()
            task.cancel()
        })
#if DEBUG
        cmuxDebugLog("cloud.create.inProcess operation=\(operationID.uuidString) workspace=\(invocation.workspaceID.uuidString) time=\(Date().timeIntervalSince1970)")
#endif
        return true
    }

    /// The tombstone's destroy for a cancelled create: in-process when the client is
    /// up, else the bundled CLI's `vm rm`. A machine the backend already forgot
    /// counts as destroyed; its workspaces close the same way a delete closes them.
    static func destroyMachineBestEffort(_ machineID: String) {
        let id = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard let client = VMClient.shared else {
            CloudVMActionLauncher.shared.destroyMachineBestEffort(id)
            return
        }
        Task { @MainActor in
            do {
                try await client.destroy(id: id)
            } catch let error as VMClientError {
                guard case .httpStatus(404, _) = error else { return }
            } catch {
                return
            }
            AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: id)
        }
    }
}
