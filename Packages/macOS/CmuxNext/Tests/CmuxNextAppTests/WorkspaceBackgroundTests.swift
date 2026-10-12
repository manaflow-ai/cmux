import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing

/// A workspace's own background (cx-t2x.5): it wins over the app's, `none` is plain glass even under
/// the app's art, clearing it follows the app again, and it survives a relaunch.
@MainActor @Suite(.serialized) struct WorkspaceBackgroundTests {
    static let gesture = PageCallContext(page: "cmux.settings", userGesture: true)
    static let work = BackdropSelection.art(.vanGoghStarryNight)

    @Test func aWorkspacePinWinsOverTheAppsArtAndClearingItFollowsTheAppAgain() {
        let app = ThemeScope(level: .room)
        let window = ThemeScope(level: .workspace, parent: app)
        app.setBackdropSelection(Self.work)
        #expect(window.backdropSelection == Self.work)

        window.pinBackdrop(.none)
        #expect(window.backdropSelection == nil)
        #expect(app.backdropSelection == Self.work)

        window.pinBackdrop(.selection(.art(.goyaSaturn)))
        #expect(window.backdropSelection == .art(.goyaSaturn))

        window.pinBackdrop(.inherit)
        #expect(window.backdropSelection == Self.work)
    }

    @Test func aWorkspaceBackgroundSurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-workspace-backgrounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "workspace-backgrounds.json")
        let key = WorkspaceBackgroundStore.key(session: "home", workspace: "ws-1")

        let first = WorkspaceBackgroundStore(url: url)
        await first.load()
        first.set("none", for: key)
        first.set(Self.work.id, for: WorkspaceBackgroundStore.key(session: "home", workspace: "ws-2"))
        await first.flush()

        let relaunched = WorkspaceBackgroundStore(url: url)
        await relaunched.load()
        #expect(relaunched.background(for: key) == "none")
        #expect(WorkspaceBackgroundStore.pin(relaunched.background(for: key), now: Date()) == BackdropPin.none)

        relaunched.set(nil, for: key)
        await relaunched.flush()
        let again = WorkspaceBackgroundStore(url: url)
        await again.load()
        #expect(again.background(for: key) == nil)
        #expect(again.backgrounds.count == 1)
    }

    @Test func eachSavedValueShowsWhatTheAppsSettingWould() {
        let now = Date()
        #expect(WorkspaceBackgroundStore.pin(nil, now: now) == .inherit)
        #expect(WorkspaceBackgroundStore.pin("none", now: now) == BackdropPin.none)
        #expect(WorkspaceBackgroundStore.pin("daily", now: now) == .selection(.art(.daily(on: now))))
        #expect(WorkspaceBackgroundStore.pin(Self.work.id, now: now) == .selection(Self.work))
        #expect(WorkspaceBackgroundStore.pin("__gone__", now: now) == .inherit)
    }

    /// The picker's This Workspace choice: read, preview, end, save, clear; refused without a
    /// gesture or for a value `appearance.background` refuses.
    @Test func thePickerReadsPreviewsAndSavesAWorkspacesBackground() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cnc-wsbg-\(UUID().uuidString)/cmux.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let store = WorkspaceBackgroundStore(url: nil)
        await store.load()
        var preview: String?? = nil
        let window = ThemeScope(level: .workspace, parent: ThemeScope(level: .room))
        func show() { window.pinBackdrop(WorkspaceBackgroundStore.pin(preview ?? store.background(for: "ws"), now: Date())) }
        let page = SettingsPageProvider(settings: settings)
        page.workspaceBackgrounds = SettingsWorkspaceBackgrounds(
            title: { $0 == "ws" ? "Research" : nil },
            value: { store.background(for: $0) },
            set: { value, id in preview = nil; store.set(value, for: id); show() },
            preview: { value, _ in preview = value; show() })
        func call(_ op: String, _ params: JSONValue, gesture: Bool = true) async throws -> JSONValue {
            try await page.call(op, params: params, context: gesture ? Self.gesture : PageCallContext(page: "cmux.settings"))
        }

        let read = try await call("cmux.settings.backdrop.workspace", ["workspace": "ws"], gesture: false)
        #expect(read["title"] == "Research")
        #expect(read["value"] == .null)

        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "value": .string(Self.work.id)])
        #expect(window.backdropSelection == Self.work)
        #expect(store.background(for: "ws") == nil)
        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "end": true])
        #expect(window.backdropSelection == nil)

        _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "value": "none"])
        #expect(store.background(for: "ws") == "none")
        _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "value": .null])
        #expect(store.background(for: "ws") == nil)

        await #expect(throws: PageError.self) {
            _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "value": "none"], gesture: false)
        }
        await #expect(throws: PageError.self) {
            _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "value": "__not_a_backdrop__"])
        }
        await #expect(throws: PageError.self) {
            _ = try await call("cmux.settings.backdrop.workspace", ["workspace": "gone"])
        }
    }
}
