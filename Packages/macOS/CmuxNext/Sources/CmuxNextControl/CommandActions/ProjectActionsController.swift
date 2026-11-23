public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSettings
import Foundation

/// Registers the focused project's own actions (its actions file, which the session host finds,
/// checks and lists: `project.actions.list`) as `cmuxProject.<name>`, titled with the project's
/// name, for the focused local terminal's folder. They follow the focus and the terminal's `cd`.
///
/// Trust: a repository's actions file is text from whoever wrote the repository, and cmux has no
/// trust prompt. So nothing runs one unasked: an action only shows in the palette under the
/// project's name, and it runs when the person picks it, in the project's folder.
@MainActor
public final class ProjectActionsController {
    /// The id prefix of a project's actions.
    public static let actionIDPrefix = "cmuxProject."

    private var commands: CommandActionSet
    private let folder: @MainActor @Sendable () -> String?
    private let connection: @MainActor () -> DaemonConnection?
    private var shown: String?
    private var following: Task<Void, Never>?
    private var listing: Task<Void, Never>?

    /// - Parameters:
    ///   - folder: The focused local terminal's folder, nil when the focus has none.
    ///   - connection: This Mac's session host.
    ///   - run: Runs a picked action (the App's `ConfigCommandRunner`).
    public init(registry: ActionRegistry, folder: @escaping @MainActor @Sendable () -> String?,
                connection: @escaping @MainActor () -> DaemonConnection?,
                run: @escaping @MainActor (ConfigCommandAction, ActionInvocation) -> Void) {
        self.commands = CommandActionSet(registry: registry, run: run)
        self.folder = folder
        self.connection = connection
    }

    /// Lists the focused folder's actions now, then follows the focused terminal's folder.
    public func start() {
        guard following == nil else { return }
        // task-owner: this controller (cancelled in stop); event-driven (Observation).
        following = Task { [weak self, folder] in
            for await folder in ObservationStream({ folder() }) {
                self?.show(folder)
            }
        }
    }

    public func stop() {
        following?.cancel()
        following = nil
        listing?.cancel()
        listing = nil
        commands.apply([])
    }

    /// Focus moved in a window, a change the observation cannot see.
    public func focusChanged() {
        show(folder())
    }

    private func show(_ folder: String?) {
        guard folder != shown else { return }
        shown = folder
        listing?.cancel()
        guard let folder, let connection = connection() else { return commands.apply([]) }
        // task-owner: one listing; a newer folder cancels it.
        listing = Task { [weak self] in
            let listing = try? await ProjectActionsClient(connection: connection).list(folder: folder)
            guard !Task.isCancelled, let self, self.shown == folder else { return }
            self.apply(listing ?? ProjectActionsClient.Listing())
        }
    }

    private func apply(_ listing: ProjectActionsClient.Listing) {
        let project = listing.projectRoot.map { ($0 as NSString).lastPathComponent } ?? ""
        let actions = listing.actions.filter { $0.source == .project }.map { Self.command($0, project: project) }
        commands.apply(actions, keywords: project.isEmpty ? [] : [project])
    }

    /// The action as a command that runs in the project's folder: a new terminal tab there, or the
    /// pane's terminal after a `cd` into it.
    static func command(_ action: ProjectActionsClient.Action, project: String) -> ConfigCommandAction {
        let inTerminal = action.target == "currentTerminal"
        let text = inTerminal ? action.cwd.map { "cd -- \(shellQuoted($0)) && \(action.command)" } ?? action.command : action.command
        var command = ConfigCommandAction(name: action.name, title: "\(project): \(action.title)", tooltip: action.tooltip,
                                          command: text, target: inTerminal ? .currentTerminal : .newTabInCurrentPane,
                                          cwd: inTerminal ? nil : action.cwd)
        command.actionID = actionIDPrefix + action.name
        return command
    }

    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
