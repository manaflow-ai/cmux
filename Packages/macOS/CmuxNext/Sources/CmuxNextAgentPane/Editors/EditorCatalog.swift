public import AppKit
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextWindowRules

/// The system calls Open in Editor needs: which app a bundle id names on this Mac, and opening
/// folders or files with one. `NSWorkspace` in the app; tests pass a fake.
@MainActor public protocol EditorApplications: AnyObject {
    func applicationURL(bundleID: String) -> URL?
    func open(_ urls: [URL], withApplicationAt app: URL)
}

/// This Mac's apps, through `NSWorkspace`.
@MainActor public final class WorkspaceEditorApplications: EditorApplications {
    private let workspace: NSWorkspace
    public init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    public func applicationURL(bundleID: String) -> URL? { workspace.urlForApplication(withBundleIdentifier: bundleID) }

    public func open(_ urls: [URL], withApplicationAt app: URL) {
        workspace.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The code editors installed on this Mac, the person's default first (Open in Editor, Open In ▸,
/// the palette's Open In page, the agent pane's `editors.list` and `file.open where: editor`).
/// The table and the pick are Rust's (`window_editors_table`, `window_editors_pick` with
/// cmux.json `editor.default`); this asks the system only which bundle ids resolve. A menu or the
/// palette reads it several times while it builds, so one detection serves a short window
/// (``reuseInterval``), and nothing runs between opens: no polling, no observers.
@MainActor public final class EditorCatalog {
    /// One installed editor: its table row and the app that opens folders for it.
    public struct Installed: Equatable {
        public var editor: WindowRules.Editor
        public var app: URL
        public var id: String { editor.id }
        public var name: String { editor.name }
    }

    /// What one detection found: the installed editors in pick order (the default first).
    public struct Detected: Equatable {
        public var ordered: [Installed]
        public var `default`: Installed? { ordered.first }
        public func editor(_ id: String) -> Installed? { ordered.first { $0.id == id } }
    }

    /// How long one detection answers, so one menu or palette open asks the system once.
    public static let reuseInterval: TimeInterval = 1

    private let applications: any EditorApplications
    private let configured: @MainActor () -> String?
    private let textEditor: @MainActor () -> String?
    private let table: @MainActor () -> [WindowRules.Editor]?
    private let pick: @MainActor ([String], String?) -> WindowRules.EditorPick?
    private let now: () -> Date
    private var cachedTable: [WindowRules.Editor]?
    private var cached: (at: Date, configured: String?, detected: Detected)?

    /// `configured`: cmux.json `editor.default` (nil for `auto`); `textEditor`: `files.textEditor`, which picks the
    /// default under `auto` when it names an editor of the table. `table` and `pick` default to the Rust ops; a test passes its own.
    public init(applications: any EditorApplications = WorkspaceEditorApplications(),
                configured: @escaping @MainActor () -> String?, textEditor: @escaping @MainActor () -> String? = { nil },
                table: @escaping @MainActor () -> [WindowRules.Editor]? = { WindowRules().editorsTable() },
                pick: @escaping @MainActor ([String], String?) -> WindowRules.EditorPick? = { WindowRules().pickEditor(installed: $0, configured: $1) },
                now: @escaping () -> Date = { Date() }) {
        self.applications = applications
        self.configured = configured
        self.textEditor = textEditor
        self.table = table
        self.pick = pick
        self.now = now
    }

    /// The installed editors now, the default first; empty when none is installed or the FFI does not answer.
    public func detected() -> Detected {
        let rows = cachedTable ?? table() ?? []
        if !rows.isEmpty { cachedTable = rows }
        let configured = configured() ?? Self.tableID(of: textEditor(), in: rows)
        if let cached, cached.configured == configured, now().timeIntervalSince(cached.at) < Self.reuseInterval { return cached.detected }
        var apps: [String: URL] = [:]
        for row in rows {
            // Installed: any of its bundle ids names an app, the first in the row's order wins.
            if let app = row.bundleIds.lazy.compactMap(applications.applicationURL(bundleID:)).first { apps[row.id] = app }
        }
        let installed = rows.map(\.id).filter { apps[$0] != nil }
        let order = installed.isEmpty ? [] : (pick(installed, configured)?.ordered ?? installed)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let detected = Detected(ordered: order.compactMap { id in byID[id].flatMap { row in apps[id].map { Installed(editor: row, app: $0) } } })
        cached = (now(), configured, detected)
        return detected
    }

    /// The table editor `app` names (`files.textEditor`: an app name, bundle id or app path), if it names one.
    nonisolated static func tableID(of app: String?, in rows: [WindowRules.Editor]) -> String? {
        guard let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { return nil }
        let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return rows.first { $0.bundleIds.contains(app) || $0.id == app.lowercased() || $0.name.lowercased() == name || $0.name.lowercased() == app.lowercased() }?.id
    }

    /// Forgets the last detection (an editor installed meanwhile shows at the next open).
    public func invalidate() { cached = nil }

    /// The app of editor `id`, or of the default editor when `id` is nil; nil when it is not installed.
    public func application(_ id: String? = nil) -> URL? {
        try? editor(id).get().app
    }

    /// Editor `id` (an action's `app`), else the default editor; or the reason the person reads: no
    /// editor installed, or `id` names one that is not.
    public func editor(_ id: String?) -> Result<Installed, EditorRefusal> {
        let detected = detected()
        guard let id, !id.isEmpty else { return detected.default.map { .success($0) } ?? .failure(EditorRefusal(reason: EditorStrings.noEditor)) }
        return detected.editor(id).map { .success($0) } ?? .failure(EditorRefusal(reason: EditorStrings.notInstalled(id)))
    }

    /// Opens `urls` in editor `id`, else the default editor; nil, or the reason it did not.
    public func open(_ urls: [URL], in id: String?) -> String? {
        switch editor(id) {
        case .success(let editor): applications.open(urls, withApplicationAt: editor.app); return nil
        case .failure(let refusal): return refusal.reason
        }
    }

    /// Opens `folder` with `app` (Open Current Directory's `app`): an installed editor by its id, Finder
    /// (`finder`), or any app by bundle id, name or path (``application(named:)``); none is the default editor,
    /// else Finder. False when `app` names no app here.
    public func openFolder(_ folder: URL, with app: String?) -> Bool {
        if app == "finder" { NSWorkspace.shared.openInBackground(folder); return true }
        guard let app, !app.isEmpty else {
            if open([folder], in: nil) != nil { NSWorkspace.shared.openInBackground(folder) }
            return true
        }
        if detected().editor(app) != nil { return open([folder], in: app) == nil }
        guard let url = Self.application(named: app) else { return false }
        applications.open([folder], withApplicationAt: url)
        return true
    }

    /// An app by bundle id, `.app` path, or name in the Applications folders; one rule for every "open with" field.
    nonisolated public static func application(named app: String) -> URL? {
        if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) { return byID }
        let expanded = (app as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app"), FileManager.checked.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded, isDirectory: true) }
        let name = app.hasSuffix(".app") ? app : app + ".app"
        let folders = ["/Applications", "/System/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.lazy.map { "\($0)/\(name)" }.first { FileManager.checked.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The editors as an action argument's choices (Open In ▸), the default first.
    public func choices() -> [ActionEnumCase] {
        detected().ordered.map { ActionEnumCase(value: $0.id, title: $0.name) }
    }

    /// The agent pane's `editors.list` reply: the default, then the others in order.
    public func pageList() -> [String: Any] {
        let detected = detected()
        let entry = { (editor: Installed) -> [String: Any] in ["id": editor.id, "name": editor.name] }
        return [
            "default": detected.default.map(entry) ?? NSNull(),
            "others": detected.ordered.dropFirst().map(entry),
        ]
    }

    /// Open In ▸ and the palette's `app` step list the installed editors (``ActionSuggestions/editors``), the
    /// default first and checked on the rows of `ids`.
    public func supplyChoices(to registry: ActionRegistry, checkedOn ids: Set<ActionID>) {
        let suggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak self] in $0 == ActionSuggestions.editors ? self?.choices() ?? [] : suggestions?($0) ?? [] }
        let menuChoices = registry.menuChoices
        registry.menuChoices = { [weak self] source -> [ActionEnumCase]? in source == ActionSuggestions.editors ? self?.choices() : menuChoices?(source) }
        for id in ids {
            ActionTargetTitles.setChoiceState(id, in: registry) { [weak self] _ in self?.detected().default?.id }
        }
    }
}

/// Why an editor cannot open: the reason the person reads.
public nonisolated struct EditorRefusal: Error, Equatable {
    public var reason: String
}

/// The page's `file.open where: editor` app, as a path's Open in Text Editor: `files.textEditor` when set, else
/// `editor.default`'s editor, else the Mac's app for source code or plain text (``AgentPaneFileOpen/editorApplication(workspace:)``).
@MainActor public final class CatalogEditorApps: AgentPaneEditorApps {
    private let catalog: EditorCatalog
    private let textEditor: @MainActor () -> String?
    private let fallback: any AgentPaneEditorApps

    public init(catalog: EditorCatalog, textEditor: @escaping @MainActor () -> String? = { nil }, fallback: any AgentPaneEditorApps = AgentPaneWorkspaceEditors()) {
        self.catalog = catalog
        self.textEditor = textEditor
        self.fallback = fallback
    }

    public func application() -> URL? {
        textEditor().flatMap { $0.isEmpty ? nil : EditorCatalog.application(named: $0) } ?? catalog.application() ?? fallback.application()
    }

    public func open(_ url: URL, withApplicationAt app: URL) { fallback.open(url, withApplicationAt: app) }
}

public struct EditorStrings {
    public init() {}
    public static var noEditor: String {
        String(localized: "editor.refusal.noEditor", defaultValue: "No code editor is installed on this Mac.", bundle: .module)
    }

    public static func notInstalled(_ id: String) -> String {
        String(format: String(localized: "editor.refusal.notInstalled", defaultValue: "The editor %@ is not installed on this Mac.", bundle: .module), id)
    }

    public static var finder: String { String(localized: "editor.openIn.finder", defaultValue: "Finder", bundle: .module) }
    public static var terminal: String { String(localized: "editor.openIn.terminal", defaultValue: "Terminal", bundle: .module) }
}
