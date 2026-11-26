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
    /// The most project names the preview lists before an ellipsis.
    static let listedProjects = 8
    static let planTimeout = Duration.seconds(120)
    /// Each project's machine is made in turn; the run ends when they all are.
    static let applyTimeout = Duration.seconds(3_600)

    /// The part of `cmux migrate`'s plan (cmux-migrate `plan.rs`) the preview shows.
    nonisolated struct Plan: Decodable, Equatable, Sendable {
        nonisolated struct Project: Decodable, Equatable, Sendable {
            var key: String
            var name: String
            var checked: Bool = true

            init(key: String, name: String, checked: Bool = true) {
                self.key = key
                self.name = name
                self.checked = checked
            }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                key = try values.decode(String.self, forKey: .key)
                name = try values.decode(String.self, forKey: .name)
                checked = try values.decodeIfPresent(Bool.self, forKey: .checked) ?? true
            }

            enum CodingKeys: String, CodingKey { case key, name, checked }
        }
        nonisolated struct Carry: Decodable, Equatable, Sendable {
            var checked: Bool = true

            init(checked: Bool = true) { self.checked = checked }

            init(from decoder: any Decoder) throws {
                checked = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .checked) ?? true
            }

            enum CodingKeys: String, CodingKey { case checked }
        }
        nonisolated struct Unsupported: Decodable, Equatable, Sendable {
            var what: String
            var why: String
        }

        var projects: [Project] = []
        var carry: [Carry] = []
        var warnings: [String] = []
        var unsupported: [Unsupported] = []

        init(projects: [Project] = [], carry: [Carry] = [], warnings: [String] = [], unsupported: [Unsupported] = []) {
            self.projects = projects
            self.carry = carry
            self.warnings = warnings
            self.unsupported = unsupported
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            projects = try values.decodeIfPresent([Project].self, forKey: .projects) ?? []
            carry = try values.decodeIfPresent([Carry].self, forKey: .carry) ?? []
            warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
            unsupported = try values.decodeIfPresent([Unsupported].self, forKey: .unsupported) ?? []
        }

        enum CodingKeys: String, CodingKey { case projects, carry, warnings, unsupported }

        /// The projects apply makes machines for.
        var moving: [Project] { projects.filter(\.checked) }
    }

    /// How one `cmux` run ended: its exit status and its last stderr line.
    nonisolated struct Ran: Equatable, Sendable {
        var status: Int32
        var reason: String
    }

    /// Runs `cmux <arguments>` within the timeout (a test's fake).
    let cli: @MainActor ([String], Duration) async throws -> Ran
    /// Shows the preview; true when the person pressed Move.
    let confirm: @MainActor (Plan) async -> Bool
    /// Where the plan is written between the dry run and apply.
    let folder: URL

    /// On the app's bundled `cmux`.
    public init(cli bundled: BundledExecutable) {
        self.init(cli: { arguments, timeout in
            guard let binary = await bundled.resolve() else { throw MoveToAutoCloudFailure.noCLI }
            let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, timeout: timeout,
                                                     clock: ContinuousClock())
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            return Ran(status: result.status, reason: stderr.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)")
        }, confirm: { await Self.showPreview($0) })
    }

    init(cli: @escaping @MainActor ([String], Duration) async throws -> Ran,
         confirm: @escaping @MainActor (Plan) async -> Bool,
         folder: URL = FileManager.default.temporaryDirectory) {
        self.cli = cli
        self.confirm = confirm
        self.folder = folder
    }

    /// Runs the move; returns how many projects it moved, nil when the person declined.
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
        let planned = try await cli(["migrate", "plan", "laptop", "--out", file.path], Self.planTimeout)
        guard planned.status == 0 else { throw MoveToAutoCloudFailure.plan(planned.reason) }
        // Read and decoded off the main thread: a Mac with many checkouts writes a long plan.
        let plan = try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(Plan.self, from: Data(blockingContentsOf: file)) }.value
        guard !plan.moving.isEmpty else {
            Self.toast(MoveToAutoCloudStrings.nothing)
            return 0
        }
        guard await confirm(plan) else { return nil }
        let applied = try await cli(["migrate", "apply", file.path], Self.applyTimeout)
        guard applied.status == 0 else { throw MoveToAutoCloudFailure.apply(applied.reason) }
        progress?(1)
        Self.toast(MoveToAutoCloudStrings.moved)
        return plan.moving.count
    }

    private static func showPreview(_ plan: Plan) async -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let spec = CmuxDialogSpec(usesTransientMaterial: true,
            title: MoveToAutoCloudStrings.previewTitle,
            lines: previewLines(plan),
            buttons: [.cancel(), CmuxDialogButton(id: moveButton, title: MoveToAutoCloudStrings.previewButton, role: .default)],
            identifier: identifier
        )
        return await CmuxDialogCenter.shared.present(spec, in: window.map { .window($0) } ?? .app).button == moveButton
    }

    /// The projects first (count, then each machine's name), then what comes along, the plan's
    /// warnings as the CLI wrote them, what stays on this Mac and that nothing here changes.
    static func previewLines(_ plan: Plan) -> [String] {
        let moving = plan.moving
        var lines = [MoveToAutoCloudStrings.projects(moving.count)]
        for project in moving.prefix(listedProjects) { lines.append("• \(String(project.name.prefix(64)))") }
        if moving.count > listedProjects { lines.append("• …") }
        let carry = plan.carry.filter(\.checked).count
        if carry > 0 { lines.append(MoveToAutoCloudStrings.carry(carry)) }
        for warning in plan.warnings.prefix(listedProjects) { lines.append(String(warning.prefix(200))) }
        if !plan.unsupported.isEmpty {
            lines.append(MoveToAutoCloudStrings.unsupported(plan.unsupported.count))
            for item in plan.unsupported.prefix(listedProjects) {
                lines.append("• \(String(item.what.prefix(64))): \(String(item.why.prefix(120)))")
            }
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
