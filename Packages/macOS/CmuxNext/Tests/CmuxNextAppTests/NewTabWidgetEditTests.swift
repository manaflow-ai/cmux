@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextApps
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The New Tab page's edit mode (Leo 2026-10-20, as an iPhone's home screen): right-click > Edit New
/// Tab, then drag a widget, ✕ it, or + to add one. The page sends `newTab.editWidgets`; the App saves
/// a drag as `tabs.newTabWidgets.order` and a ✕ as the widget's own switch, as Settings would, and +
/// opens App Store Features on New Tab. The next page gets the widgets in the saved order.
@MainActor @Suite(.serialized) struct NewTabWidgetEditTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static func settings(_ json: String = "{}") async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-newtab-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, directory)
    }

    static func snapshot(_ widgets: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["tabs": .object(["newTabWidgets": .object(widgets)])]), validDensities: [], validMetrics: [])
    }

    @Test func thePageGetsTheMovableWidgetsInTheSavedOrder() {
        let on: [String: JSONValue] = ["projects": .bool(true), "chats": .bool(true), "styleDots": .bool(true)]
        #expect(Self.snapshot(on).newTabWidgets.ids == ["greeting", "projects", "chats", "styleDots"])
        var reordered = on
        reordered["order"] = .array([.string("chats"), .string("projects")])
        let snapshot = Self.snapshot(reordered)
        #expect(snapshot.newTabWidgets.ids == ["greeting", "chats", "projects", "styleDots"], "a place does not turn a widget on")
        #expect(snapshot.newTabWidgets.order == ["chats", "projects", "actions"], "left out follows in Settings' order")
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func aBadOrderKeepsWhatItCanAndSaysWhy() {
        let snapshot = Self.snapshot(["order": .array([.string("chats"), .string("weather"), .string("chats"), .number(3)])])
        #expect(snapshot.newTabWidgets.order == ["chats", "projects", "actions"])
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabWidgets.order" }, "\(snapshot.diagnostics)")
        #expect(Self.snapshot(["order": .string("chats")]).newTabWidgets.order == NewTabWidgetSettings.movable)
    }

    @Test func theOrderIsASettingAgentsMaySet() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabWidgetSettings.orderPath))
        #expect(descriptor.defaultValue == .array(NewTabWidgetSettings.movable.map(JSONValue.string)))
        #expect(descriptor.accepts(.array([.string("chats"), .string("projects")])))
        #expect(!descriptor.accepts(.array([.string("weather")])))
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.order"))
    }

    @Test func theEditModesRequestsReachTheApp() async {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var edits: [AgentPaneNewTabEdit] = []
        model.onEditNewTab = { edits.append($0) }
        let send = { (params: [String: Any]) in
            await model.respond(to: AgentPaneRequest(body: ["method": "newTab.editWidgets", "params": params]))
        }
        #expect(await send(["edit": "remove", "widget": "projects"])["ok"] as? Bool == true)
        _ = await send(["edit": "order", "order": ["chats", "projects"]])
        _ = await send(["edit": "add"])
        #expect(edits == [.remove("projects"), .order(["chats", "projects"]), .add])

        // A bad edit never reaches the App.
        #expect(await send(["edit": "remove", "widget": "../order"])["ok"] as? Bool != true)
        _ = await send(["edit": "order", "order": "chats"])
        _ = await send(["edit": "rename"])
        #expect(edits.count == 3)
    }

    @Test func aDragAndAnXAreSavedAsSettingsWould() async throws {
        let (settings, directory) = try await Self.settings(#"{"tabs":{"newTabWidgets":{"projects":true,"chats":true}}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The page shows Projects and Chats; Quick Actions (off) keeps its place in the saved order.
        try await settings.setNewTabWidgetOrder(["chats", "projects"])
        #expect(settings.snapshot.newTabWidgets.ids == ["greeting", "chats", "projects"])
        #expect(settings.fileRoot.value(at: NewTabWidgetSettings.orderPath) == .array([.string("chats"), .string("actions"), .string("projects")]))
        try await settings.setNewTabWidgetOrder(["projects", "chats"])
        #expect(settings.fileRoot.value(at: NewTabWidgetSettings.orderPath) == nil, "the default order leaves the file")
        #expect(NewTabWidgetSettings.reordered(["actions", "chats", "projects"], shown: ["projects", "chats"]) == ["actions", "projects", "chats"])
        #expect(NewTabWidgetSettings.reordered(NewTabWidgetSettings.movable, shown: ["chats", "chats", "projects"]) == ["chats", "actions", "projects"])

        // ✕ on a widget that is off by default takes its key out; on the greeting (on by default) writes false.
        try await settings.removeNewTabWidget("chats")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "chats"]) == nil)
        try await settings.removeNewTabWidget("greeting")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "greeting"]) == .bool(false))
        #expect(settings.snapshot.newTabWidgets.ids == ["projects"])
        // Only a widget's switch: never the order, or a key that is not a widget.
        await #expect(throws: SettingNotInSchema.self) { try await settings.removeNewTabWidget("order") }
        await #expect(throws: SettingNotInSchema.self) { try await settings.removeNewTabWidget("weatherCity") }
    }

    /// `cmux action run appStore.show --tab features --category newTab`, and the page's +.
    @Test func plusOpensAppStoreFeaturesOnNewTab() {
        #expect(AppFeature.Category(argument: "newTab") == .newTab)
        #expect(AppFeature.Category(argument: " NEWTAB ") == .newTab)
        #expect(AppFeature.Category(argument: "labs") == nil)
        let model = AppStoreModel(client: AppsClient(transport: EditModeOfflineAppsTransport()))
        model.query = "glass"
        model.present(appID: nil, tab: nil, category: .newTab)
        #expect(model.tab == .features)
        #expect(model.featureCategory == .newTab)
        #expect(model.query.isEmpty, "a search would hide the category's cards")
    }
}

/// An app supervisor that is never reachable (the Features tab does not need one).
private final class EditModeOfflineAppsTransport: AppsTransport {
    var availability: AppsAvailability { .unavailable(.notConnected) }
    var onEvent: ((AppsTransportEvent) -> Void)?
    private static var offline: AppsTransportError { AppsTransportError(message: "offline", connectionLost: true) }

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply { throw Self.offline }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        throw Self.offline
    }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) { throw Self.offline }
    func unmount(mountID: String) async throws(AppsTransportError) { throw Self.offline }
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) { throw Self.offline }
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        throw Self.offline
    }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { throw Self.offline }
}
