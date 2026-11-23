import AppKit
import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import CmuxNextWakeups

/// Settings > Appearance > Customization Library (webviews `CustomizeLibraryCard.tsx`):
/// `cmux.settings.customize.library {verb, name?, position?}` runs `cmux --json customize library
/// VERB …` through the bundled CLI and answers its JSON, or its error envelope on a refusal (a
/// toggle while a preview is open). The library is the CLI's (cmux-customize `library.rs`): what
/// is kept, the stack's order and the rule that the higher entry that is on wins, so the card and
/// the CLI never differ, and this type keeps no state.
///
/// `list` only reads, so the page may ask for it; `on`, `off`, `order` and `remove` rewrite the
/// person's settings and files, so they run only on the person's click or key in the page
/// (`context.userGesture`, the host's record) or a call they approved, as Agent integrations'
/// installs do: a page script alone gets `cmux.app.user_only`.
///
/// The customize doctor (cmux-customize `library/doctor.rs`, Settings' doctor card) rides the same
/// op: `doctor` reads `cmux --json customize doctor`; `doctor-fix` {id, fix: off|remove|restore|follow-default},
/// `doctor-dismiss` {id} and `doctor-recover` run its `fix`, `dismiss` and `recover` verbs;
/// `doctor-open` {id} reads the report
/// and opens the finding's `path` (a folder revealed in Finder, a file in its default app), the
/// `open` fix the CLI has no verb for. All but `doctor` need the person's click.
@MainActor
public final class SettingsCustomizeLibrary: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.customize.library"
    /// The page verbs that change the library or the person's files, or open an app.
    nonisolated static let changes: Set<String> = ["on", "off", "order", "remove", "doctor-fix", "doctor-dismiss", "doctor-open", "doctor-recover"]
    nonisolated static let timeout: Duration = .seconds(60)

    /// One CLI run: arguments in, exit status, stdout and stderr out.
    public typealias Runner = @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)
    /// Opens a finding's path: `isFolder` reveals it in Finder, else it opens in its default app.
    public typealias Opener = @MainActor (_ url: URL, _ isFolder: Bool) -> Void

    private let cli: @MainActor () async -> URL?
    private let settingsFile: @MainActor () -> URL?
    private let runCLI: Runner
    private let open: Opener

    /// `settingsFile` points the CLI at the settings file the app reads (`CMUX_NEXT_CONFIG_FILE`) when
    /// it is not the CLI's default; nil or the default keeps the CLI's own (see `environment`).
    public init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?, runCLI: @escaping Runner,
                open: @escaping Opener = SettingsCustomizeLibrary.openInBackground(_:isFolder:)) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.runCLI = runCLI
        self.open = open
    }

    /// The app's: the bundled CLI run as a child process.
    public convenience init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?) {
        self.init(cli: cli, settingsFile: settingsFile, runCLI: { try await SettingsCustomizeLibrary.run($0, $1, $2) })
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        let arguments = try Self.arguments(params)
        let verb = params["verb"]?.stringValue ?? ""
        if Self.changes.contains(verb) {
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(verb) needs a click in the page")
            }
        }
        guard let binary = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        let environment = Self.environment(ProcessInfo.processInfo.environment, settingsFile: settingsFile())
        let (status, stdout, stderr) = try await runCLI(binary, arguments, environment)
        // A refusal is the CLI's envelope on stderr (`code`, `message`): the page shows its words.
        let answer = (try? JSONValue.parse(status == 0 ? stdout : stderr)) ?? .object([:])
        guard verb == "doctor-open", status == 0 else { return answer }
        let id = params["id"]?.stringValue ?? ""
        guard let path = Self.openPath(answer, id: id) else {
            throw PageError(code: "customize.doctor.open", message: "\(id) has no file to open")
        }
        let url = URL(fileURLWithPath: path)
        let folder = await Self.isFolder(url)
        open(url, folder)
        return .object(["opened": .string(path), "doctor": answer["doctor"] ?? .null])
    }

    /// The path of finding `id` in a `doctor` report, nil when the report has no such finding or it
    /// names no absolute path.
    nonisolated static func openPath(_ answer: JSONValue, id: String) -> String? {
        let finding = answer["doctor"]?["findings"]?.arrayValue?.first { $0["id"]?.stringValue == id }
        guard let path = finding?["path"]?.stringValue, path.hasPrefix("/") else { return nil }
        return path
    }

    /// Whether `url` is a folder, read off the main actor (a stat of the person's file).
    @concurrent nonisolated static func isFolder(_ url: URL) async -> Bool {
        (try? url.blockingResourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// The app's opener: never on the main thread (`NSWorkspace` background calls).
    public static func openInBackground(_ url: URL, isFolder: Bool) {
        if isFolder { NSWorkspace.shared.revealInBackground([url]) } else { NSWorkspace.shared.openInBackground(url) }
    }

    /// The CLI's words for one page call: `--json customize library VERB [NAME [POSITION]]`, or
    /// `--json customize doctor [fix ID FIX | dismiss ID | recover]`. A name or an id is an argument of its
    /// own, never a flag (the CLI refuses one starting with `-` too).
    nonisolated static func arguments(_ params: JSONValue) throws -> [String] {
        let verb = params["verb"]?.stringValue ?? ""
        let base = ["--json", "customize", "library"]
        let doctor = ["--json", "customize", "doctor"]
        func findingID() throws -> String {
            guard let id = params["id"]?.stringValue, !id.isEmpty, !id.hasPrefix("-") else {
                throw PageError.invalidParams("id is a doctor finding")
            }
            return id
        }
        switch verb {
        case "doctor", "doctor-open":
            if verb == "doctor-open" { _ = try findingID() }
            return doctor
        case "doctor-fix":
            let id = try findingID()
            guard let fix = params["fix"]?.stringValue, ["off", "remove", "restore", "follow-default"].contains(fix) else {
                throw PageError.invalidParams("fix is off, remove, restore or follow-default")
            }
            return doctor + ["fix", id, fix]
        case "doctor-dismiss":
            return doctor + ["dismiss", try findingID()]
        case "doctor-recover":
            return doctor + ["recover"]
        case "list":
            return base + ["list"]
        case "on", "off", "remove", "order":
            guard let name = params["name"]?.stringValue, !name.isEmpty, !name.hasPrefix("-") else {
                throw PageError.invalidParams("name is a library entry")
            }
            guard verb == "order" else { return base + [verb, name] }
            guard let position = params["position"]?.stringValue, isPosition(position) else {
                throw PageError.invalidParams("position is top, bottom or a number from 1")
            }
            return base + [verb, name, position]
        default:
            throw PageError.invalidParams("verb is list, on, off, order, remove, doctor, doctor-fix, doctor-dismiss, doctor-open or doctor-recover")
        }
    }

    /// The CLI's environment: the app's own, naming the app's settings file only when it is not the
    /// CLI's default (`~/.config/cmux/cmux-next.json`). An override also moves the CLI's library
    /// state into the config folder (cmux-customize `Roots::from`), so naming the default file would
    /// hide every entry an ordinary `cmux customize` run kept.
    nonisolated static func environment(_ base: [String: String], settingsFile: URL?) -> [String: String] {
        var environment = base
        guard let file = settingsFile else { return environment }
        if let home = environment["HOME"], !home.isEmpty,
           file.standardizedFileURL.path == URL(fileURLWithPath: home).appendingPathComponent(".config/cmux/cmux-next.json").standardizedFileURL.path {
            return environment
        }
        environment["CMUX_NEXT_CONFIG_FILE"] = file.path
        return environment
    }

    nonisolated static func isPosition(_ text: String) -> Bool {
        if text == "top" || text == "bottom" { return true }
        guard (1...6).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return Int(text).map { $0 >= 1 } ?? false
    }

    /// The bundled CLI, off the main actor, with a deadline; a change runs to its end even when the
    /// page goes away, so the library is never left half written by a closed page.
    @concurrent public nonisolated static func run(_ cli: URL, _ arguments: [String],
                                                   _ environment: [String: String]) async throws -> (Int32, Data, Data) {
        let request = ProcessRequest(cli, arguments, environment: environment, errorOutput: .separate,
                                     timeout: timeout, onCancel: .finish)
        let outcome = try await AsyncProcess().run(request)
        return (outcome.succeeded ? 0 : max(outcome.status, 1), outcome.output, outcome.errorOutput)
    }
}

/// Settings > Appearance > Looks (webviews `LooksGalleryCard.tsx`): `cmux.settings.looks {verb, id?,
/// reference?, scheme?, yes?, ids?}` runs `cmux --json setup VERB …` through the bundled CLI and
/// answers its JSON, or its error envelope (an install with no `yes` answers `setup.needs_consent`
/// with the card the page shows before it installs). The catalog, the previews, the layers and every
/// write are the CLI's (cmux-customize `setup`, cmux-tui `cli/setup/repo.rs`); this type keeps no state.
///
/// `gallery` and `preview` only read, so the page may ask for them; `install`, `remove`, `on`, `off`
/// and `order` change the person's setup, so they run only on a click or key in the page or a call
/// they approved, as the library's verbs do.
@MainActor
public final class SettingsLooks: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.looks"
    /// The verbs that change the person's setup.
    nonisolated static let changes: Set<String> = ["install", "remove", "on", "off", "order"]

    private let cli: @MainActor () async -> URL?
    private let settingsFile: @MainActor () -> URL?
    private let runCLI: SettingsCustomizeLibrary.Runner

    public init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?,
                runCLI: @escaping SettingsCustomizeLibrary.Runner) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.runCLI = runCLI
    }

    /// The app's: the bundled CLI run as a child process.
    public convenience init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?) {
        self.init(cli: cli, settingsFile: settingsFile, runCLI: { try await SettingsCustomizeLibrary.run($0, $1, $2) })
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        let arguments = try Self.arguments(params)
        if let verb = arguments.dropFirst(2).first, Self.changes.contains(verb) {
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(verb) needs a click in the page")
            }
        }
        guard let binary = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        let environment = SettingsCustomizeLibrary.environment(ProcessInfo.processInfo.environment, settingsFile: settingsFile())
        let (status, stdout, stderr) = try await runCLI(binary, arguments, environment)
        return (try? JSONValue.parse(status == 0 ? stdout : stderr)) ?? .object([:])
    }

    /// The CLI's words for one page call: `--json setup VERB …`. Every id and reference is an argument
    /// of its own and never a flag.
    nonisolated static func arguments(_ params: JSONValue) throws -> [String] {
        let base = ["--json", "setup"]
        let word = { (key: String) throws -> String in
            guard let value = params[key]?.stringValue, isWord(value) else {
                throw PageError.invalidParams("\(key) is a look id or repo")
            }
            return value
        }
        switch params["verb"]?.stringValue ?? "" {
        case "gallery":
            return base + ["gallery"]
        case "preview":
            let scheme = params["scheme"]?.stringValue == "light" ? "light" : "dark"
            return base + ["preview", try word("id"), "--scheme", scheme]
        case "install":
            let yes = params["yes"]?.boolValue == true
            return base + ["install", try word("reference")] + (yes ? ["--yes"] : [])
        case let verb where verb == "remove" || verb == "on" || verb == "off":
            return base + [verb, try word("id")]
        case "order":
            guard case .array(let values)? = params["ids"], !values.isEmpty else {
                throw PageError.invalidParams("ids is the looks' order, top first")
            }
            let ids = try values.map { value -> String in
                guard let id = value.stringValue, isWord(id) else { throw PageError.invalidParams("ids are look ids") }
                return id
            }
            return base + ["order"] + ids
        default:
            throw PageError.invalidParams("verb is gallery, preview, install, remove, on, off or order")
        }
    }

    nonisolated static func isWord(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && text.count <= 512 && !text.contains(where: { $0.isNewline })
    }
}
