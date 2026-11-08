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

    /// The most projects one listing reads to tell which of Conductor's repositories are listed
    /// already (the daemon keeps at most 1,000).
    static let listedProjects = 1_000

    let host: any ConductorImportHost
    /// The daemon calls the run makes (a test's fake); nil when this Mac's daemon is not connected.
    let daemon: @MainActor () -> (any ConductorImportDaemon)?
    /// Shows the preview; true when the person pressed Import.
    let confirm: @MainActor (ConductorImportPlan) async -> Bool

    public init(host: any ConductorImportHost) {
        self.init(host: host, daemon: { host.conductorDaemon.map { LiveConductorImportDaemon(connection: $0) } },
                  confirm: { await Self.showPreview($0) })
    }

    init(host: any ConductorImportHost, daemon: @escaping @MainActor () -> (any ConductorImportDaemon)?,
         confirm: @escaping @MainActor (ConductorImportPlan) async -> Bool) {
        self.host = host
        self.daemon = daemon
        self.confirm = confirm
    }

    /// Runs the import; returns how many workspaces it opened, nil when the person declined.
    /// A failure shows its toast, then throws.
    public func run(progress: (@MainActor (Double) -> Void)? = nil) async throws -> Int? {
        do {
            return try await importing(progress: progress)
        } catch {
            Self.toast(ConductorImportStrings.agentFailed)
            throw error
        }
    }

    private func importing(progress: (@MainActor (Double) -> Void)?) async throws -> Int? {
        guard let daemon = daemon() else { throw DaemonError.notConnected }
        let reply = try await daemon.plan()
        if let error = reply.error { throw ConductorImportFailure.plan(error) }
        guard let plan = reply.plan else {
            Self.toast(ConductorImportStrings.agentAllHere)
            return 0
        }
        // Which repositories are not listed yet. A failed listing counts every one as not listed:
        // the preview then shows, and adding a listed project again changes nothing.
        let listed = Set((try? await daemon.projectPaths(limit: Self.listedProjects)) ?? [])
        let unlisted = plan.projects.filter { project in
            project.skipped == nil && project.path.map { !listed.contains($0) } == true
        }
        // Nothing to make, add, save or explain: the preview would say nothing new.
        guard !plan.adopting.isEmpty || !unlisted.isEmpty || !plan.recipes.isEmpty || !plan.recoverable.isEmpty
            || !plan.cleanup.isEmpty || plan.warnings.contains(where: { $0.code == "agent-source-scan-failed" }) else {
            Self.toast(plan.hasConductor ? ConductorImportStrings.allHere : ConductorImportStrings.agentAllHere)
            return 0
        }
        guard await confirm(plan) else { return nil }

        // A cut-off run's half-made workspaces close before they are made again. One that will not
        // close stops the run: making its replacement would leave two. One already gone is fine.
        for key in plan.cleanup.compactMap(host.conductorWorkspaceKey) {
            do {
                try await daemon.closeWorkspace(key)
            } catch let error as DaemonError where error.isWorkspaceNotFound {
                continue
            }
        }
        let run = UUID().uuidString.lowercased()
        // A repository that could not be added keeps its workspaces unrecorded, so Import Again
        // offers them with it; the other repositories still come over, and the run ends failed.
        var failedProjects: [String] = []
        var failedRecipes: [String] = []
        for project in unlisted {
            guard let path = project.path else { continue }
            do {
                try await daemon.addProject(path: path, idempotencyKey: "conductor-import-\(run)-project-\(project.repoID)")
            } catch {
                failedProjects.append(project.repoID)
            }
        }
        // Each project's worktree recipe, as the preview showed it, unless the user saved one since
        // (the daemon checks and saves in one step). One that cannot be saved fails the run at its
        // end; the others and the workspaces still come over.
        for (project, recipe) in plan.recipes where !failedProjects.contains(project.repoID) {
            do {
                try await daemon.saveRecipe(recipe, idempotencyKey: "conductor-import-\(run)-recipe-\(project.repoID)")
            } catch {
                failedRecipes.append(project.repoID)
            }
        }
        let adopting = plan.adopting.filter { !failedProjects.contains($0.project.repoID) }
        var opened = 0
        for (index, item) in adopting.enumerated() {
            guard let path = item.workspace.path else { continue }
            let id = item.workspace.id
            // The key is in the ledger before the workspace exists: a run cut off here leaves a
            // pending entry naming it, which the next run's plan lists for cleanup.
            let key = WorkspaceKey.generate()
            try await daemon.record(workspace: id, stage: .pending, cmuxWorkspace: key.rawValue, runCompleted: false,
                                    idempotencyKey: "conductor-import-\(run)-\(id)-pending")
            let made = try await host.openConductorWorkspace(folder: path, name: item.workspace.name, key: key)
            do {
                try await daemon.record(workspace: id, stage: .done, cmuxWorkspace: made,
                                        runCompleted: failedProjects.isEmpty && failedRecipes.isEmpty
                                            && index == adopting.count - 1,
                                        idempotencyKey: "conductor-import-\(run)-\(id)-done")
            } catch let error as DaemonError where error.isConductorImportConflict {
                // Another run took this workspace after this one's pending record: its workspace is
                // the one the ledger keeps, so this one closes rather than stay a duplicate. Any other
                // failure may have come after the record was kept, so nothing closes: the ledger's
                // pending entry still names this workspace, and the next run cleans it up if needed.
                try await daemon.closeWorkspace(key)
                throw error
            }
            opened += 1
            progress?(Double(index + 1) / Double(adopting.count))
        }
        if !failedProjects.isEmpty { throw ConductorImportFailure.projects(failedProjects) }
        if !failedRecipes.isEmpty { throw ConductorImportFailure.recipes(failedRecipes) }
        if opened > 0 {
            Self.toast(plan.hasConductor ? ConductorImportStrings.opened : ConductorImportStrings.agentOpened)
        } else if !plan.recoverable.isEmpty {
            Self.toast(ConductorImportStrings.recoverable(plan.recoverable.count))
        } else {
            Self.toast(plan.hasConductor ? ConductorImportStrings.allHere : ConductorImportStrings.agentAllHere)
        }
        return opened
    }

    private static func showPreview(_ plan: ConductorImportPlan) async -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let spec = CmuxDialogSpec(
            title: plan.hasConductor ? ConductorImportStrings.previewTitle : ConductorImportStrings.agentPreviewTitle,
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
        let recipes = plan.recipes
        if !recipes.isEmpty { lines.append(ConductorImportStrings.recipes(recipes.count)) }
        for (project, recipe) in recipes.prefix(listedWorkspaces) {
            lines.append("• \(String(project.name.prefix(64))): \(recipeSummary(recipe))")
        }
        if recipes.count > listedWorkspaces { lines.append("• …") }
        if plan.warnings.contains(where: { $0.code == "agent-source-scan-failed" }) {
            lines.append(contentsOf: plan.warnings.filter { $0.code == "agent-source-scan-failed" }.map(\.detail))
        }
        if plan.hasConductor {
            if plan.warnings.contains(where: { $0.code == "archive-deletes-folder" }) { lines.append(ConductorImportStrings.archiveWarning) }
            lines.append(ConductorImportStrings.deadline)
        }
        return lines
    }

    /// A recipe as the preview shows it, before it is saved: each command as written under its
    /// key in cmux's recipe (`setup`, `run`, `teardown`) and the files to copy (`include`).
    static func recipeSummary(_ recipe: ConductorImportPlan.Recipe) -> String {
        let shown = { (text: String) in text.count > 80 ? "\(text.prefix(80))…" : text }
        var parts: [String] = []
        if let setup = recipe.setup { parts.append("setup: \(shown(setup))") }
        if let run = recipe.run { parts.append("run: \(shown(run))") }
        if let teardown = recipe.teardown { parts.append("teardown: \(shown(teardown))") }
        if let include = recipe.include, !include.isEmpty { parts.append("include: \(shown(include.joined(separator: ", ")))") }
        return parts.joined(separator: " · ")
    }

    private static func toast(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "conductorImport", message: message), in: window)
    }
}

extension DaemonError {
    /// `conductor_import.record`'s refusal of a record whose cmux workspace is not the ledger's
    /// (`validation.invalid` naming `cmux_workspace`): the record was not kept.
    var isConductorImportConflict: Bool {
        guard case .command(_, _, let code?, let details, _) = self, code == "validation.invalid" else { return false }
        return details?["field"]?.stringValue == "cmux_workspace"
    }
}

enum ConductorImportFailure: Error, Equatable, CustomStringConvertible {
    case plan(String)
    /// These Conductor repositories (by id) could not be added as projects.
    case projects([String])
    /// These Conductor repositories' (by id) worktree recipes could not be saved.
    case recipes([String])

    var description: String {
        switch self {
        case .plan(let reason): "conductor import plan: \(reason)"
        case .projects(let ids): "conductor import: projects not added: \(ids.joined(separator: ", "))"
        case .recipes(let ids): "conductor import: worktree recipes not saved: \(ids.joined(separator: ", "))"
        }
    }
}
