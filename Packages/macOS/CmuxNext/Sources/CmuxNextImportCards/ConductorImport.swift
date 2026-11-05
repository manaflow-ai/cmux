public import CmuxNextDaemon
import AppKit
import CmuxNextDesign
import CmuxNextImportSuggestions
import Foundation

/// What Import from Conductor needs from the App: this Mac's daemon, and its workspaces.
@MainActor
public protocol ConductorImportHost: AnyObject {
    /// This Mac's daemon, which reads Conductor's files and keeps the import's ledger.
    var conductorDaemon: DaemonConnection? { get }
    /// The key of open workspace `id`, to close one a cut-off run half made.
    func conductorWorkspaceKey(_ id: String) -> WorkspaceKey?
    /// Opens a workspace at `folder` named `name` with key `key`; returns its id.
    func openConductorWorkspace(folder: String, name: String, key: WorkspaceKey) async throws -> String
}

/// Import from Conductor (the Conductor card in Settings › Import). The daemon reads
/// Conductor's database and folders read-only and plans the import
/// (`conductor_import.plan`); the person sees that plan and confirms it; then each of
/// Conductor's repositories is listed as a project and each live workspace opens as a cmux
/// workspace at its own folder, on its branch, where its chats already are. Archived
/// workspaces are listed as recoverable and not made. Every workspace is recorded in the
/// import's ledger before and after it is made, so a rerun makes nothing twice and a run cut
/// off midway replaces the workspace it half made.
@MainActor
public struct ConductorImport {
    static let importButton = "import"
    static let identifier = "cmux.dialog.conductorImport"
    /// The most workspace names the preview lists before an ellipsis.
    static let listedWorkspaces = 8

    let host: any ConductorImportHost

    public init(host: any ConductorImportHost) {
        self.host = host
    }

    /// Runs the import; returns how many workspaces it opened, nil when the person declined.
    /// A failure shows its toast, then throws.
    public func run(progress: (@MainActor (Double) -> Void)? = nil) async throws -> Int? {
        do {
            return try await importing(progress: progress)
        } catch {
            Self.toast(ConductorImportStrings.failed)
            throw error
        }
    }

    private func importing(progress: (@MainActor (Double) -> Void)?) async throws -> Int? {
        guard let connection = host.conductorDaemon else { throw DaemonError.notConnected }
        let client = ConductorImportClient(connection: connection)
        let reply = try await client.plan()
        if let error = reply.error { throw ConductorImportFailure.plan(error) }
        guard let plan = reply.plan, !plan.adopting.isEmpty else {
            Self.toast(ConductorImportStrings.allHere)
            return 0
        }
        guard await Self.confirm(plan) else { return nil }

        // A cut-off run's half-made workspaces close before they are made again.
        for key in plan.cleanup.compactMap(host.conductorWorkspaceKey) {
            _ = try? await connection.closeWorkspace(key, endTerminals: true)
        }
        let projects = ProjectStateClient(connection: connection)
        for project in plan.projects where project.skipped == nil {
            guard let path = project.path else { continue }
            try? await projects.add(path: path, idempotencyKey: "conductor-import-project-\(project.repoID)")
        }
        let adopting = plan.adopting
        let run = UUID().uuidString.lowercased()
        var opened = 0
        for (index, item) in adopting.enumerated() {
            guard let path = item.workspace.path else { continue }
            let id = item.workspace.id
            // The key is in the ledger before the workspace exists: a run cut off here leaves a
            // pending entry naming it, which the next run's plan lists for cleanup.
            let key = WorkspaceKey.generate()
            try await client.record(workspace: id, stage: .pending, cmuxWorkspace: key.rawValue,
                                    idempotencyKey: "conductor-import-\(run)-\(id)-pending")
            let made = try await host.openConductorWorkspace(folder: path, name: item.workspace.name, key: key)
            try await client.record(workspace: id, stage: .done, cmuxWorkspace: made, runCompleted: index == adopting.count - 1,
                                    idempotencyKey: "conductor-import-\(run)-\(id)-done")
            opened += 1
            progress?(Double(index + 1) / Double(adopting.count))
        }
        Self.toast(opened > 0 ? ConductorImportStrings.opened : ConductorImportStrings.allHere)
        return opened
    }

    private static func confirm(_ plan: ConductorImportPlan) async -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let spec = CmuxDialogSpec(
            title: ConductorImportStrings.previewTitle,
            lines: previewLines(plan),
            buttons: [.cancel(), CmuxDialogButton(id: importButton, title: ConductorImportStrings.previewButton, role: .default)],
            identifier: identifier
        )
        return await CmuxDialogCenter.shared.present(spec, in: window.map { .window($0) } ?? .app).button == importButton
    }

    /// Counts first, then each workspace adopted (name and branch), then what does not come
    /// over and the warning about archiving in Conductor.
    static func previewLines(_ plan: ConductorImportPlan) -> [String] {
        let adopting = plan.adopting
        var lines = [
            ConductorImportStrings.projects(plan.projects.filter { $0.skipped == nil }.count),
            ConductorImportStrings.adopted(adopting.count),
        ]
        for item in adopting.prefix(listedWorkspaces) {
            let name = String(item.workspace.name.prefix(64))
            lines.append(item.workspace.branch.map { "• \(name) (\(String($0.prefix(64))))" } ?? "• \(name)")
        }
        if adopting.count > listedWorkspaces { lines.append("• …") }
        let chats = adopting.compactMap(\.workspace.chats?.transcripts).reduce(0, +)
        if chats > 0 { lines.append(ConductorImportStrings.chats(chats)) }
        if !plan.recoverable.isEmpty { lines.append(ConductorImportStrings.recoverable(plan.recoverable.count)) }
        if !plan.cleanup.isEmpty { lines.append(ConductorImportStrings.cleanup(plan.cleanup.count)) }
        let names = Set(plan.projects.filter { $0.skipped == nil }.flatMap(\.envNames)).sorted()
        if !names.isEmpty { lines.append(ConductorImportStrings.environment(names.prefix(12).joined(separator: ", "))) }
        if plan.warnings.contains(where: { $0.code == "archive-deletes-folder" }) { lines.append(ConductorImportStrings.archiveWarning) }
        lines.append(ConductorImportStrings.deadline)
        return lines
    }

    private static func toast(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "conductorImport", message: message), in: window)
    }
}

enum ConductorImportFailure: Error, CustomStringConvertible {
    case plan(String)

    var description: String {
        switch self {
        case .plan(let reason): "conductor import plan: \(reason)"
        }
    }
}
