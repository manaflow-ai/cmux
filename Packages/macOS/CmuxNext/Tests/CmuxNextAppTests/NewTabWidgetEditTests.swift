import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextSettingsWindow
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
        #expect(Self.snapshot(on).newTabWidgets.ids == ["projects", "chats", "styleDots"])
        var reordered = on
        reordered["order"] = .array([.string("chats"), .string("projects")])
        let snapshot = Self.snapshot(reordered)
        #expect(snapshot.newTabWidgets.ids == ["chats", "projects", "styleDots"], "a place does not turn a widget on")
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
        _ = await send(["edit": "show", "widget": "actions"])
        #expect(edits == [.remove("projects"), .order(["chats", "projects"]), .add, .show("actions")])

        // A bad edit never reaches the App.
        #expect(await send(["edit": "remove", "widget": "../order"])["ok"] as? Bool != true)
        _ = await send(["edit": "order", "order": "chats"])
        _ = await send(["edit": "rename"])
        _ = await send(["edit": "show", "widget": "../actions"])
        #expect(edits.count == 4)
    }

    @Test func aDragAndAnXAreSavedAsSettingsWould() async throws {
        let (settings, directory) = try await Self.settings(#"{"tabs":{"newTabWidgets":{"greeting":true,"projects":true,"chats":true}}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The page shows Projects and Chats; Quick Actions (off) keeps its place in the saved order.
        try await settings.setNewTabWidgetOrder(["chats", "projects"])
        #expect(settings.snapshot.newTabWidgets.ids == ["greeting", "chats", "projects"])
        #expect(settings.fileRoot.value(at: NewTabWidgetSettings.orderPath) == .array([.string("chats"), .string("actions"), .string("projects")]))
        try await settings.setNewTabWidgetOrder(["projects", "chats"])
        #expect(settings.fileRoot.value(at: NewTabWidgetSettings.orderPath) == nil, "the default order leaves the file")
        #expect(NewTabWidgetSettings.reordered(["actions", "chats", "projects"], shown: ["projects", "chats"]) == ["actions", "projects", "chats"])
        #expect(NewTabWidgetSettings.reordered(NewTabWidgetSettings.movable, shown: ["chats", "chats", "projects"]) == ["chats", "actions", "projects"])

        // ✕ on a widget that is off by default takes its key out, the headline's too (off by default).
        try await settings.removeNewTabWidget("chats")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "chats"]) == nil)
        try await settings.removeNewTabWidget("greeting")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "greeting"]) == nil)
        #expect(settings.snapshot.newTabWidgets.ids == ["projects"])
        // Only a widget's switch: never the order, or a key that is not a widget.
        await #expect(throws: SettingNotInSchema.self) { try await settings.removeNewTabWidget("order") }
        await #expect(throws: SettingNotInSchema.self) { try await settings.removeNewTabWidget("weatherCity") }
    }

    /// The New Tab page's second dot (Claude Minimal with the quick actions, Leo 2026-10-23) turns
    /// the quick actions on as their Settings switch would; the first and third dots turn them off.
    @Test func aDotTurnsTheQuickActionsOnAndOff() async throws {
        let (settings, directory) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(settings.snapshot.newTabWidgets.ids == [])
        try await settings.showNewTabWidget("actions")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "actions"]) == .bool(true))
        #expect(settings.snapshot.newTabWidgets.ids == ["actions"])
        try await settings.removeNewTabWidget("actions")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "actions"]) == nil, "off is the default, so the key leaves the file")
        // The headline is off by default (Leo 2026-10-22): showing it writes true, a ✕ takes the key out.
        try await settings.showNewTabWidget("greeting")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "greeting"]) == .bool(true))
        try await settings.removeNewTabWidget("greeting")
        #expect(settings.fileRoot.value(at: ["tabs", "newTabWidgets", "greeting"]) == nil)
        await #expect(throws: SettingNotInSchema.self) { try await settings.showNewTabWidget("order") }
    }

    /// A `show` with a well-formed name that is no widget (it passes the request's name check) is
    /// refused by the schema, and the settings file stays as it was. The weather widget fetches
    /// from the network, so only the person turns it on, in Settings (#22775): the page's show is
    /// refused too.
    @Test func aDotsShowOfAnUnknownWidgetIsRefused() async throws {
        let (settings, directory) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AgentPaneNewTabEdit(widgetParams: ["edit": "show", "widget": "forecast"]) == .show("forecast"))
        let before = settings.fileRoot
        await #expect(throws: SettingNotInSchema.self) { try await settings.showNewTabWidget("forecast") }
        await #expect(throws: SettingNotInSchema.self) { try await settings.showNewTabWidget("weatherCity") }
        await #expect(throws: SettingUserOnly.self) { try await settings.showNewTabWidget("weather") }
        #expect(settings.fileRoot == before)
        // Still Settings' defaults: no widget on (the headline is off by default, Leo 2026-10-22).
        #expect(settings.snapshot.newTabWidgets.ids == [])
    }

    /// The spare page a new tab adopts (NewTabPage.sparePage) says `headlineOff` only for a greeting
    /// set to false in cmux.json, so Minimal keeps no room for the headline for those who had turned
    /// the greeting off; the default and a saved true keep the room.
    @Test func theSparePageSaysHeadlineOffOnlyForAGreetingSetToFalse() async throws {
        _ = NSApplication.shared
        for (json, headlineOff, ids) in [
            ("{}", nil, [String]()),
            (#"{"tabs":{"newTabWidgets":{"greeting":true}}}"#, nil, ["greeting"]),
            (#"{"tabs":{"newTabWidgets":{"greeting":false}}}"#, true, [String]()),
        ] as [(String, Bool?, [String])] {
            let (settings, directory) = try await Self.settings(json)
            defer { try? FileManager.default.removeItem(at: directory) }
            let services = AppServices(environment: AppEnvironment.current([:]))
            services.settings = settings
            let page = NewTabPage.sparePage(services)
            #expect(page.headlineOff == headlineOff, "\(json)")
            #expect(page.pageWidgets == ids, "\(json)")
        }
    }

    /// The page's + opens Settings on the widget rows: the anchor exists.
    @Test func plusOpensTheWidgetSettings() {
        #expect(SettingsAnchor(key: "tabs.newTabWidgets.greeting") != nil)
        // The sidebar edit mode's Add Items opens Settings on the sidebar's rows.
        #expect(SettingsAnchor(key: "sidebar.showProjects") != nil)
    }
}
