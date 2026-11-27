public import CmuxNextDaemon
import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextImportSuggestions
public import CmuxNextSettings
import Foundation

/// What the import cards host runs for Move this Mac to AutoCloud.
public struct AutoCloudMove {
    /// Whether the card is offered: `cloud.autoCloud` (Settings › Machines), off by default.
    public var offered: () -> Bool
    /// `cmux migrate plan laptop`'s dry run, its native preview and confirmation, then
    /// `cmux migrate apply` of that plan. How many projects moved; nil when the person declined.
    public var move: (@escaping @MainActor (Double) -> Void) async throws -> Int?

    public init(offered: @escaping () -> Bool, move: @escaping (@escaping @MainActor (Double) -> Void) async throws -> Int?) {
        self.offered = offered
        self.move = move
    }

    /// The App's: the bundled CLI and the live settings.
    public init(cli: BundledExecutable, settings: @escaping () -> SettingsController?) {
        self.init(offered: { settings().map { CloudNewWorkspaceSetting().autoCloud(in: $0.snapshot.root) } ?? false },
                  move: { progress in try await MoveToAutoCloudImport(cli: cli).run(progress: progress) })
    }
}

/// Move this Mac to AutoCloud (the AutoCloud card in Settings › Import, RFD 0173). The bundled
/// `cmux migrate plan laptop` reads this Mac's checkouts and settings and writes a dry-run plan;
/// the person sees that plan in a native preview and confirms it; then `cmux migrate apply` of
/// that same plan makes each project's machine through the signed-in app. What to move, how and
/// what was moved before (its ledger, `~/.cmux/migrate/ledger.json`) are all the CLI's: this only
/// runs it, so a rerun moves nothing twice.
@MainActor
public struct MoveToAutoCloudImport {
    static let moveButton = "move"
    static let identifier = "cmux.dialog.moveToAutoCloud"
    static let planTimeout = Duration.seconds(120)
    /// Each project's machine is made in turn; the run ends when they all are.
    static let applyTimeout = Duration.seconds(3_600)

    /// `cmux migrate plan laptop --preview --json`'s answer (cmux-migrate `preview.rs`): which
    /// projects move, what an earlier run already moved and how much of each list shows are the
    /// CLI's; this only words it.
    nonisolated struct Preview: Decodable, Equatable, Sendable {
        var moving = 0
        var names: [String] = []
        var more = false
        var carry = 0
        var warnings: [String] = []
        var left = 0
        var leftRows: [String] = []

        enum CodingKeys: String, CodingKey { case moving, names, more, carry, warnings, left, leftRows = "left_rows" }
    }

    /// How one `cmux` run ended: its exit status, its stdout and its last stderr line.
    nonisolated struct Ran: Equatable, Sendable {
        var status: Int32
        var output = Data()
        var reason: String
    }

    /// Runs `cmux <arguments>` within the timeout (a test's fake).
    let cli: @MainActor ([String], Duration) async throws -> Ran
    /// Shows the preview; true when the person pressed Move.
    let confirm: @MainActor (Preview) async -> Bool
    /// Where the plan is written between the dry run and apply.
    let folder: URL

    /// On the app's bundled `cmux`.
    public init(cli bundled: BundledExecutable) {
        self.init(cli: { arguments, timeout in
            guard let binary = await bundled.resolve() else { throw MoveToAutoCloudFailure.noCLI }
            let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, timeout: timeout,
                                                     clock: ContinuousClock())
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            return Ran(status: result.status, output: result.stdout,
                       // main-actor-ok: splits a failed run's short stderr for its last line
                       reason: stderr.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)")
        }, confirm: { await Self.showPreview($0) })
    }

    init(cli: @escaping @MainActor ([String], Duration) async throws -> Ran,
         confirm: @escaping @MainActor (Preview) async -> Bool,
         folder: URL = FileManager.default.temporaryDirectory) {
        self.cli = cli
        self.confirm = confirm
        self.folder = folder
    }

    /// Runs the move; returns how many projects it moved, nil when the person declined or
    /// nothing was left to move.
    /// A failure shows its toast, then throws.
    public func run(progress: (@MainActor (Double) -> Void)? = nil) async throws -> Int? {
        let file = folder.appending(path: "cmux-move-to-autocloud-\(UUID().uuidString.lowercased()).json", directoryHint: .notDirectory)
        do {
            let moved = try await moving(file, progress: progress)
            await Self.remove(file)
            return moved
        } catch {
            await Self.remove(file)
            Self.toast(MoveToAutoCloudStrings.failed)
            throw error
        }
    }

    /// The plan file goes once the move is done or failed, off the main thread.
    private static func remove(_ file: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: file) }.value
    }

    private func moving(_ file: URL, progress: (@MainActor (Double) -> Void)?) async throws -> Int? {
        let planned = try await cli(["migrate", "plan", "laptop", "--out", file.path, "--preview", "--json"], Self.planTimeout)
        guard planned.status == 0 else { throw MoveToAutoCloudFailure.plan(planned.reason) }
        // main-actor-ok: the planner's one preview reply, a few small fields
        let preview = try JSONDecoder().decode(Preview.self, from: planned.output)
        guard preview.moving > 0 else {
            Self.toast(MoveToAutoCloudStrings.nothing)
            return nil
        }
        guard await confirm(preview) else { return nil }
        let applied = try await cli(["migrate", "apply", file.path], Self.applyTimeout)
        guard applied.status == 0 else { throw MoveToAutoCloudFailure.apply(applied.reason) }
        progress?(1)
        Self.toast(MoveToAutoCloudStrings.moved)
        return preview.moving
    }

    private static func showPreview(_ preview: Preview) async -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let spec = CmuxDialogSpec(usesTransientMaterial: true,
            title: MoveToAutoCloudStrings.previewTitle,
            lines: previewLines(preview),
            buttons: [.cancel(), CmuxDialogButton(id: moveButton, title: MoveToAutoCloudStrings.previewButton, role: .default)],
            identifier: identifier
        )
        return await CmuxDialogCenter.shared.present(spec, in: window.map { .window($0) } ?? .app).button == moveButton
    }

    /// The projects first (count, then each machine's name), then what comes along, the plan's
    /// warnings as the CLI wrote them, what stays on this Mac and that nothing here changes.
    static func previewLines(_ preview: Preview) -> [String] {
        var lines = [MoveToAutoCloudStrings.projects(preview.moving)]
        lines += preview.names.map { "• \($0)" }
        if preview.more { lines.append("• …") }
        if preview.carry > 0 { lines.append(MoveToAutoCloudStrings.carry(preview.carry)) }
        lines += preview.warnings
        if preview.left > 0 {
            lines.append(MoveToAutoCloudStrings.unsupported(preview.left))
            lines += preview.leftRows.map { "• \($0)" }
        }
        lines.append(MoveToAutoCloudStrings.unchanged)
        return lines
    }

    private static func toast(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "moveToAutoCloud", message: message), in: window)
    }
}

nonisolated enum MoveToAutoCloudFailure: Error, Equatable, CustomStringConvertible {
    case noCLI
    case plan(String)
    case apply(String)

    var description: String {
        switch self {
        case .noCLI: "move to autocloud: this build has no cmux"
        case .plan(let reason): "cmux migrate plan: \(reason)"
        case .apply(let reason): "cmux migrate apply: \(reason)"
        }
    }
}
