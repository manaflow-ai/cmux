import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Foundation
import Testing

/// The web Settings page's host: the bridge forwards only `settings.*` and
/// the page operations, the scheme handler serves only the page directory,
/// and the interim backend answers in the daemon's shapes and codes.
@MainActor
@Suite struct SettingsWebPageTests {
    final class RecordingBackend: SettingsPageBackend {
        var requests: [(String, JSONValue)] = []
        var onChange: ((Int, [String]) -> Void)?
        func request(_ operation: String, params: JSONValue) async throws -> JSONValue {
            requests.append((operation, params))
            if operation == "settings.set" { throw SettingsPageError(code: "managed", message: "managed", details: ["reason": "r"]) }
            return ["ok": true]
        }
    }

    @Test func bridgeForwardsSettingsOperationsUnchanged() async {
        let backend = RecordingBackend()
        let bridge = SettingsPageBridge(backend: backend)
        let reply = await bridge.handle("settings.list", params: ["section": "appearance"])
        #expect(reply == ["ok": true])
        #expect(backend.requests.map(\.0) == ["settings.list"])
        #expect(backend.requests.first?.1 == ["section": "appearance"])
    }

    @Test func bridgePassesRefusalsInTheWireShape() async {
        let bridge = SettingsPageBridge(backend: RecordingBackend())
        let reply = await bridge.handle("settings.set", params: ["key": "ui.animationSpeed", "value": "fast"])
        #expect(reply["error"]?["code"] == "managed")
        #expect(reply["error"]?["details"]?["reason"] == "r")
    }

    @Test func bridgeRefusesEverythingElse() async {
        let backend = RecordingBackend()
        let bridge = SettingsPageBridge(backend: backend)
        bridge.pageOperation = { _, _ in ["page": true] }
        for operation in ["terminal.input.write", "workspace.close", "action.run", "settingsX"] {
            let reply = await bridge.handle(operation, params: [:])
            #expect(reply["error"]?["code"] == "invalid_params", "\(operation) reached something")
        }
        #expect(backend.requests.isEmpty)
        #expect(await bridge.handle("ready", params: [:]) == ["page": true])
    }

    @Test func schemeHandlerServesOnlyThePageDirectory() {
        let root = URL(fileURLWithPath: "/tmp/settings-page-root")
        let page = SettingsPageSchemeHandler.fileURL(for: URL(string: "cmux-settings://page/index.html")!, root: root)
        #expect(page?.lastPathComponent == "index.html")
        #expect(SettingsPageSchemeHandler.fileURL(for: URL(string: "cmux-settings://page/../etc/passwd")!, root: root) == nil)
        #expect(SettingsPageSchemeHandler.fileURL(for: URL(string: "cmux-settings://other/index.html")!, root: root) == nil)
        #expect(SettingsPageSchemeHandler.fileURL(for: URL(string: "cmux-agent://page/index.html")!, root: root) == nil)
    }

    @Test func thePageShipsInTheResourceBundle() throws {
        let root = try #require(SettingsPageSchemeHandler.bundledRoot())
        let html = try String(contentsOf: root.appending(path: "index.html"), encoding: .utf8)
        #expect(html.contains("default-src 'none'"))
    }

    @Test func routesRevealAKeyInItsSection() {
        #expect(SettingsWebPageView.route(section: nil, key: "appearance.backgroundOpacity")
            == "/settings/appearance?focus=appearance.backgroundOpacity")
        #expect(SettingsWebPageView.route(section: "browser", key: nil) == "/settings/browser")
        #expect(SettingsWebPageView.route(section: nil, key: nil) == nil)
    }

    func controller(_ text: String) throws -> SettingsController {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-settings-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        return SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
    }

    @Test func controllerBackendListsEveryRowAndRefusesBadValues() async throws {
        let settings = try controller(#"{"ui": {"animationSpeed": "normal"}}"#)
        await settings.reload()
        let backend = ControllerSettingsBackend(settings: settings)
        let list = try await backend.request("settings.list", params: [:])
        guard case .array(let rows)? = list["rows"] else { Issue.record("no rows"); return }
        #expect(rows.count == SettingsSchema.all.count)
        let speed = rows.first { $0["key"] == "ui.animationSpeed" }
        #expect(speed?["customized"] == true)
        await #expect(throws: SettingsPageError.self) {
            try await backend.request("settings.set", params: ["key": "ui.animationSpeed", "value": "warp"])
        }
        do {
            _ = try await backend.request("settings.set", params: ["key": "ui.animationSpeed", "value": "warp"])
        } catch let error as SettingsPageError {
            #expect(error.code == "invalid_params")
        }
        do {
            _ = try await backend.request("settings.set", params: ["key": "nope.key", "value": 1])
        } catch let error as SettingsPageError {
            #expect(error.code == "invalid_params")
        }
    }
}
