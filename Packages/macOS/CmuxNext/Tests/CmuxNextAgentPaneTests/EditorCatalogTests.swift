import CmuxNextActions
@testable import CmuxNextAgentPane
import CmuxNextWindowRules
import Foundation
import Testing

/// Open in Editor's editors: the table and the pick are Rust's, the App asks the system only which
/// bundle ids name an app here. A fake workspace stands in for NSWorkspace.
@MainActor
struct EditorCatalogTests {
    private final class FakeApplications: EditorApplications {
        var apps: [String: URL]
        var asked: [String] = []
        var opened: [([URL], URL)] = []
        init(_ apps: [String: URL]) { self.apps = apps }
        func applicationURL(bundleID: String) -> URL? { asked.append(bundleID); return apps[bundleID] }
        func open(_ urls: [URL], withApplicationAt app: URL) { opened.append((urls, app)) }
    }

    /// What the catalog asked the pick: the configured editor and the installed ids.
    private final class Picks { var calls: [(String?, [String])] = [] }

    private static let table: [WindowRules.Editor] = [
        .init(id: "vscode", name: "Visual Studio Code", bundleIds: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], symbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "cursor", name: "Cursor", bundleIds: ["com.todesktop.230313mzl4w4u92"], symbol: "cursorarrow"),
        .init(id: "zed", name: "Zed", bundleIds: ["dev.zed.Zed", "dev.zed.Zed-Preview"], symbol: "bolt"),
    ]
    private static let insiders = URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app")
    private static let zedPreview = URL(fileURLWithPath: "/Applications/Zed Preview.app")

    /// The pick puts the configured editor first when installed, else keeps the installed order.
    private static func pick(_ installed: [String], _ configured: String?) -> WindowRules.EditorPick? {
        let first = configured.flatMap { installed.contains($0) ? $0 : nil }
        let ordered = first.map { [$0] + installed.filter { $0 != first } } ?? installed
        return WindowRules.EditorPick(default: ordered.first, ordered: ordered)
    }

    private func catalog(_ apps: FakeApplications, configured: String? = nil, textEditor: String? = nil,
                         clock: @escaping () -> Date = { Date(timeIntervalSince1970: 0) }, picks: Picks? = nil) -> EditorCatalog {
        EditorCatalog(applications: apps, configured: { configured }, textEditor: { textEditor }, table: { Self.table }, pick: { installed, configured in
            picks?.calls.append((configured, installed))
            return Self.pick(installed, configured)
        }, now: clock)
    }

    /// One editor setting for people: under `auto`, a Text Editor (`files.textEditor`) that names an editor of the
    /// table, by name, bundle id or app path, is the default; `editor.default` set to an editor wins.
    @Test func aTextEditorOfTheTablePicksTheDefaultUnderAuto() {
        let apps = FakeApplications(["com.microsoft.VSCode": Self.insiders, "dev.zed.Zed": Self.zedPreview])
        for named in ["Zed", "dev.zed.Zed", "/Applications/Zed.app", "zed"] {
            #expect(catalog(apps, textEditor: named).detected().default?.id == "zed", "\(named)")
        }
        #expect(catalog(apps, textEditor: "/Applications/Visual Studio Code.app").detected().default?.id == "vscode")
        #expect(catalog(apps, textEditor: "TextEdit").detected().default?.id == "vscode", "not an editor of the table: the pick's order")
        #expect(catalog(apps, textEditor: "").detected().default?.id == "vscode")
        #expect(catalog(apps, configured: "vscode", textEditor: "Zed").detected().default?.id == "vscode")
    }

    /// The page's `file.open where: editor` app with no Text Editor set: `editor.default`'s editor, else the fallback.
    @Test func fileOpenUsesTheDefaultEditorWithNoTextEditor() {
        let apps = FakeApplications(["dev.zed.Zed": Self.zedPreview])
        #expect(CatalogEditorApps(catalog: catalog(apps), textEditor: { nil }).application() == Self.zedPreview)
        #expect(CatalogEditorApps(catalog: catalog(apps), textEditor: { "" }).application() == Self.zedPreview)
    }

    @Test func anEditorIsInstalledWhenAnyOfItsBundleIDsResolves() {
        let apps = FakeApplications(["com.microsoft.VSCodeInsiders": Self.insiders, "dev.zed.Zed-Preview": Self.zedPreview])
        let detected = catalog(apps).detected()
        #expect(detected.ordered.map(\.id) == ["vscode", "zed"])
        #expect(detected.editor("vscode")?.app == Self.insiders)
        #expect(detected.editor("cursor") == nil)
    }

    @Test func theConfiguredEditorGoesToThePickAndComesFirst() {
        let picks = Picks()
        let apps = FakeApplications(["com.microsoft.VSCode": Self.insiders, "dev.zed.Zed": Self.zedPreview])
        let detected = catalog(apps, configured: "zed", picks: picks).detected()
        #expect(picks.calls.map { $0.0 } == ["zed"])
        #expect(picks.calls.map { $0.1 } == [["vscode", "zed"]])
        #expect(detected.default?.id == "zed")
        #expect(detected.ordered.map(\.id) == ["zed", "vscode"])
    }

    @Test func noEditorInstalledAsksNoPickAndRefuses() {
        let picks = Picks()
        let apps = FakeApplications([:])
        let reason = catalog(apps, picks: picks).open([URL(fileURLWithPath: "/tmp")], in: nil)
        #expect(picks.calls.isEmpty)
        #expect(reason == EditorStrings.noEditor)
        #expect(apps.opened.isEmpty)
    }

    @Test func openUsesTheResolvedApp() {
        let apps = FakeApplications(["com.microsoft.VSCode": Self.insiders, "dev.zed.Zed": Self.zedPreview])
        let editors = catalog(apps, configured: "zed")
        let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        #expect(editors.open([folder], in: nil) == nil)
        #expect(editors.open([folder], in: "vscode") == nil)
        #expect(editors.open([folder], in: "cursor") == EditorStrings.notInstalled("cursor"))
        #expect(apps.opened.map { $0.1 } == [Self.zedPreview, Self.insiders])
        #expect(apps.opened.map { $0.0 } == [[folder], [folder]])
    }

    @Test func oneOpenAsksTheSystemOnceUntilTheWindowPasses() {
        var at = Date(timeIntervalSince1970: 100)
        let apps = FakeApplications(["dev.zed.Zed": Self.zedPreview])
        let editors = catalog(apps, clock: { at })
        _ = editors.detected()
        let asked = apps.asked.count
        _ = editors.choices(); _ = editors.pageList()
        #expect(apps.asked.count == asked, "a menu's reads share one detection")
        at += EditorCatalog.reuseInterval + 0.1
        apps.apps["com.todesktop.230313mzl4w4u92"] = Self.insiders
        #expect(editors.detected().ordered.map(\.id) == ["cursor", "zed"])
        #expect(apps.asked.count > asked)
    }

    @Test func choicesAndPageListKeepThePickOrder() {
        let apps = FakeApplications(["com.microsoft.VSCode": Self.insiders, "dev.zed.Zed": Self.zedPreview])
        let editors = catalog(apps, configured: "zed")
        #expect(editors.choices().map(\.value) == ["zed", "vscode"])
        #expect(editors.choices().map(\.title) == ["Zed", "Visual Studio Code"])
        let list = editors.pageList()
        #expect((list["default"] as? [String: Any])?["id"] as? String == "zed")
        #expect((list["default"] as? [String: Any])?["name"] as? String == "Zed")
        #expect((list["others"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["vscode"])
        let none = catalog(FakeApplications([:])).pageList()
        #expect(none["default"] is NSNull)
        #expect((none["others"] as? [[String: Any]])?.isEmpty == true)
    }

    /// The palette's Open In page: on a chat its folder's own actions, else the focused terminal's folder.
    @Test func thePalettesOpenInRunsTheFolderActionOfWhatIsFocused() {
        #expect(EditorOpenInSource.route("zed", chat: true).0 == "agentPane.openCwdInApp")
        #expect(EditorOpenInSource.route("zed", chat: true).1 == ["app": .string("zed")])
        #expect(EditorOpenInSource.route("finder", chat: true).0 == "agentPane.revealCwdInFinder")
        #expect(EditorOpenInSource.route("terminal", chat: true).0 == "agentPane.openCwdInTerminal")
        #expect(EditorOpenInSource.route("finder", chat: false).0 == "palette.terminalOpenDirectory")
        #expect(EditorOpenInSource.route("zed", chat: false).1 == ["app": .string("zed")])
    }
}
