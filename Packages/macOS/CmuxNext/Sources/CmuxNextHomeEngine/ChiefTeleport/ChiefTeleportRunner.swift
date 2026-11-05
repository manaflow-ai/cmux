public import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
public import Foundation

/// Runs one Chief move or rollback for the app's actions (`chief.moveTo`, `chief.moveRollback`),
/// each step on the bundled `cmux chief move` (one implementation with the CLI and MCP), and shows
/// every step on ``ChiefTeleportModel/phase`` (the location chip): the dry run whose report the
/// person reads and confirms, the move, `move reach` on the target, then the result. A Cloud session
/// token goes through a 0600 file the runner deletes when the step ends, never the command line.
///
/// The app passes its dialogs and the token writer; tests pass closures and a fake `run`:
///
/// ```swift
/// let runner = ChiefTeleportRunner(model: model, cli: cli, interactive: false, writeToken: { throw CocoaError(.fileNoSuchFile) },
///                                  confirm: { _, _, _, _ in true }, show: { _, _ in }, run: { _, _, _ in .init(ok: true, text: "") })
/// ```
@MainActor
public struct ChiefTeleportRunner {
    /// One command's exit and its output (stdout and stderr together).
    public struct Output: Equatable, Sendable {
        public var ok: Bool
        public var text: String

        public init(ok: Bool, text: String) {
            self.ok = ok
            self.text = text
        }
    }

    /// Runs `executable` with `arguments`, bounded by `timeout`.
    public typealias Run = @MainActor (_ executable: URL, _ arguments: [String], _ timeout: Duration) async -> Output

    private let model: ChiefTeleportModel
    private let cli: URL
    private let interactive: Bool
    private let writeToken: @MainActor () async throws -> (folder: URL, file: URL)
    private let confirm: @MainActor (_ title: String, _ body: String, _ button: String, _ identifier: String) async -> Bool
    private let show: @MainActor (_ title: String, _ body: String) -> Void
    private let run: Run
    private let userHome: String

    /// - Parameters:
    ///   - model: The teleport state the steps show on; its ``ChiefTeleportModel/home`` is the home that moves.
    ///   - cli: The bundled `cmux` CLI.
    ///   - interactive: A person asked (a menu, the palette): dialogs show; a script's run shows none.
    ///   - writeToken: Writes the Cloud session token to a 0600 file in a 0700 folder of its own.
    ///   - confirm: Asks the person (title, text, button, dialog identifier); true goes on.
    ///   - show: Shows a step's result (title, text).
    ///   - run: Runs a command (default: a child process).
    ///   - userHome: The user's home folder, for the target home's `~/…` path.
    public init(model: ChiefTeleportModel, cli: URL, interactive: Bool,
                writeToken: @escaping @MainActor () async throws -> (folder: URL, file: URL),
                confirm: @escaping @MainActor (_ title: String, _ body: String, _ button: String, _ identifier: String) async -> Bool,
                show: @escaping @MainActor (_ title: String, _ body: String) -> Void,
                run: @escaping Run = ChiefTeleportRunner.process,
                userHome: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.model = model
        self.cli = cli
        self.interactive = interactive
        self.writeToken = writeToken
        self.confirm = confirm
        self.show = show
        self.run = run
        self.userHome = userHome
    }

    /// Starts moving the Chief to `target` (its `--to` value `to`): the chip shows the dry run on
    /// this turn, the steps follow in the returned work (nil when it moved or the person said no).
    public func move(_ target: ChiefMoveTarget, to: String) -> ActionWork {
        let title = target.displayName
        model.phase = .checking(title)
        let runner = self
        return Task { await runner.moveSteps(target, to: to, title: title) }
    }

    private func moveSteps(_ target: ChiefMoveTarget, to: String, title: String) async -> ActionWorkFailure? {
        let sourceHome = model.home.path
        let token: (folder: URL, file: URL)?
        if case .cloud = target.kind {
            do { token = try await writeToken() } catch {
                model.phase = .failed(title, reason: String(describing: error))
                return ActionWorkFailure(ChiefTeleportStrings.failedTitle(title) + ": " + String(describing: error))
            }
        } else {
            token = nil
        }
        defer { if let token { Self.remove(token.folder) } }
        let plan = ChiefMovePlan(to: to, kind: target.kind, sourceHome: sourceHome,
                                 targetHome: ChiefMovePlan.targetHome(home: sourceHome, userHome: userHome), tokenFile: token?.file.path)
        let report = await run(cli, plan.dryRun, .seconds(180))
        guard report.ok else { return fail(title, report.text, mayHaveApplied: false) }
        if interactive {
            guard await confirm(ChiefTeleportStrings.confirmTitle(title), report.text, ChiefTeleportStrings.move, "cmux.dialog.chief.move") else {
                model.phase = .idle
                return nil
            }
        }
        model.phase = .moving(title)
        let moved = await run(cli, plan.move, .seconds(1800))
        model.refresh()  // a failed move may still have marked the home moved
        guard moved.ok else { return fail(title, moved.text, mayHaveApplied: true) }
        var summary = moved.text
        switch plan.reach {
        case .cli(let arguments):
            model.phase = .verifying(title)
            summary += "\n\n" + (await run(cli, arguments, .seconds(120))).text
        case .remote(let command):
            model.phase = .verifying(title)
            summary += "\n\n" + (await run(URL(fileURLWithPath: "/usr/bin/env"), command, .seconds(120))).text
        case .none:
            break
        }
        model.phase = .done(title)
        if interactive { show(ChiefTeleportStrings.doneTitle(title), summary) }
        return nil
    }

    private func fail(_ title: String, _ text: String, mayHaveApplied: Bool) -> ActionWorkFailure {
        model.phase = .failed(title, reason: text)
        if interactive { show(ChiefTeleportStrings.failedTitle(title), text) }
        return ActionWorkFailure(text, mayHaveApplied: mayHaveApplied)
    }

    /// Starts rolling the last move back: the chip shows it on this turn; the returned work asks
    /// the person (when interactive), runs `cmux chief move rollback` on the model's home, reads the
    /// home again and answers the command's output.
    public func rollback() -> @MainActor () async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let previous = model.phase
        let fromCloud = model.location == .cloud
        model.phase = .rollingBack
        let runner = self
        return { await runner.rollbackSteps(previous: previous, fromCloud: fromCloud) }
    }

    private func rollbackSteps(previous: ChiefTeleportPhase, fromCloud: Bool) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        if interactive {
            guard await confirm(ChiefTeleportStrings.rollbackConfirmTitle, ChiefTeleportStrings.rollbackConfirmBody,
                                ChiefTeleportStrings.rollbackButton, "cmux.dialog.chief.rollback") else {
                model.phase = previous
                return .success([:])
            }
        }
        let token: (folder: URL, file: URL)?
        if fromCloud {
            do { token = try await writeToken() } catch {
                model.phase = previous
                return .failure(ActionWorkFailure(ChiefTeleportStrings.rollbackFailedTitle + ": " + String(describing: error)))
            }
        } else {
            token = nil
        }
        defer { if let token { Self.remove(token.folder) } }
        let result = await run(cli, ChiefMovePlan.rollback(sourceHome: model.home.path, tokenFile: token?.file.path), .seconds(300))
        await model.refresh().value
        guard result.ok else {
            model.phase = previous
            if interactive { show(ChiefTeleportStrings.rollbackFailedTitle, result.text) }
            return .failure(ActionWorkFailure(result.text, mayHaveApplied: true))
        }
        model.phase = .rolledBack
        if interactive { show(ChiefTeleportStrings.rolledBackTitle, result.text) }
        return .success(["output": .string(result.text)])
    }

    /// Deletes a token folder off the main thread.
    private static func remove(_ folder: URL) {
        // task-owner: none; one bounded delete of a 0700 folder with one file
        Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: folder) }
    }

    /// Runs a command as a child process (``ProcessRunner``), its stdout and stderr as one text.
    public static func process(_ executable: URL, _ arguments: [String], _ timeout: Duration) async -> Output {
        do {
            let result = try await ProcessRunner.run(executable: executable, arguments: arguments, environment: nil,
                                                     timeout: timeout, clock: ContinuousClock())
            let text = [result.stdout, result.stderr].map { String(decoding: $0, as: UTF8.self) }
                .filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Output(ok: result.status == 0, text: text)
        } catch {
            return Output(ok: false, text: String(describing: error))
        }
    }
}
