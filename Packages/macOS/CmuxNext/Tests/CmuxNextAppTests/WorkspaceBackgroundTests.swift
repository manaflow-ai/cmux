import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
import CmuxNextWakeups

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

        window.pinBackdrop(.selection(.art(.friedrichForestMoonlight)))
        #expect(window.backdropSelection == .art(.friedrichForestMoonlight))

        window.pinBackdrop(.inherit)
        #expect(window.backdropSelection == Self.work)
    }

    /// The window draws its room's background: the shown workspace's own, and the app's again on a
    /// top page (Home, Settings) or a workspace without one.
    @Test func theWindowShowsItsShownWorkspacesBackgroundAndATopPageTheApps() {
        let app = ThemeScope(level: .room)
        let room = ThemeScope(level: .room, parent: app)
        let pinned = ThemeScope(level: .workspace, parent: room)
        let plain = ThemeScope(level: .workspace, parent: room)
        app.setBackdropSelection(Self.work)
        pinned.pinBackdrop(.none)

        room.show(pinned)
        #expect(room.backdropSelection == nil)
        room.show(nil)
        #expect(room.backdropSelection == Self.work)
        room.show(plain)
        #expect(room.backdropSelection == Self.work)
        room.show(pinned)
        pinned.pinBackdrop(.selection(.art(.friedrichForestMoonlight)))
        #expect(room.backdropSelection == .art(.friedrichForestMoonlight))
    }

    /// A workspace's own Opacity over art: its window draws exactly that tint, however low, and a
    /// top page the window's.
    @Test func aWorkspacesOpacityTintsItsArt() {
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.pinBackdropTint(0.8)
        room.show(workspace)
        #expect(room.backdropTintOpacity == 0.8)
        room.show(nil)
        #expect(room.backdropTintOpacity == nil)
        workspace.pinBackdropTint(1)
        #expect(workspace.backdropTintOpacity == 1)
        workspace.pinBackdropTint(1.5)
        #expect(workspace.backdropTintOpacity == 1)
        // A hand-edited "nan" follows the work's tint rather than turning the window opaque.
        workspace.pinBackdropTint(.nan)
        #expect(workspace.backdropTintOpacity == nil)

        let tokens = ThemeTokens.unresolved
        let own = WindowBackdrop(tokens, selection: Self.work)
        let dense = WindowBackdrop(tokens, selection: Self.work, tintOpacity: 0.9)
        let clear = WindowBackdrop(tokens, selection: Self.work, tintOpacity: 0)
        #expect(dense.tintOpacity == 0.9)
        #expect(dense.tintOpacity >= own.tintOpacity)
        #expect(clear.tintOpacity == 0)
        // 100% is opaque: the window hides the art (2026-10-21, "all the way to 100%").
        #expect(WindowBackdrop(tokens, selection: Self.work, tintOpacity: 1).isOpaque)
        // Without art the window's own opacity stands.
        #expect(WindowBackdrop(tokens, tintOpacity: 0.3) == WindowBackdrop(tokens))
    }

    @Test func aWorkspaceBackgroundSurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-workspace-backgrounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "workspace-backgrounds.json")
        let key = WorkspaceBackgroundStore.key(session: "home", workspace: "ws-1")

        let first = WorkspaceBackgroundStore(url: url, runner: BackgroundWork())
        await first.load()
        first.set("none", for: key)
        first.set(Self.work.id, for: WorkspaceBackgroundStore.key(session: "home", workspace: "ws-2"))
        await first.flush()

        let relaunched = WorkspaceBackgroundStore(url: url, runner: BackgroundWork())
        await relaunched.load()
        #expect(relaunched.background(for: key) == "none")
        #expect(WorkspaceBackgroundStore.pin(relaunched.background(for: key), now: Date()) == BackdropPin.none)

        relaunched.set(nil, for: key)
        await relaunched.flush()
        let again = WorkspaceBackgroundStore(url: url, runner: BackgroundWork())
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
        // A workspace pinned to a work since removed from the set follows the app's background.
        #expect(WorkspaceBackgroundStore.pin("goya-saturn", now: now) == .inherit)
    }

    /// The picker's This Workspace choice: read, preview, end, save, clear; refused without a
    /// gesture or for a value `appearance.background` refuses.
    @Test func thePickerReadsPreviewsAndSavesAWorkspacesBackground() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cnc-wsbg-\(UUID().uuidString)/cmux.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let store = WorkspaceBackgroundStore(url: nil, runner: BackgroundWork())
        await store.load()
        var preview: String?? = nil
        let window = ThemeScope(level: .workspace, parent: ThemeScope(level: .room))
        func show() { window.pinBackdrop(WorkspaceBackgroundStore.pin(preview ?? store.background(for: "ws"), now: Date())) }
        let page = SettingsPageProvider(settings: settings, on: linklessMainWork())
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
        // Resting on a tile is a pointer move, and closing Settings ends the preview long after
        // the last click: neither needs a gesture.
        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "end": true], gesture: false)
        #expect(window.backdropSelection == nil)
        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "value": .string(Self.work.id)], gesture: false)
        #expect(window.backdropSelection == Self.work)
        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "end": true], gesture: false)

        _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "value": "none"])
        #expect(store.background(for: "ws") == "none")
        _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "value": .null])
        #expect(store.background(for: "ws") == nil)

        // This Workspace's Opacity: previewed while the slider moves, saved, cleared, 0...1 only.
        var tint: Double?
        var tintPreview: Double?? = nil
        page.workspaceBackgrounds?.opacity = SettingsWorkspaceOpacity(
            value: { _ in tintPreview ?? tint }, set: { value, _ in tintPreview = nil; tint = value },
            preview: { value, _ in tintPreview = value })
        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "opacity": 0.7], gesture: false)
        #expect(try await call("cmux.settings.backdrop.workspace", ["workspace": "ws"])["opacity"] == 0.7)
        #expect(tint == nil)
        _ = try await call("cmux.settings.backdrop.workspace.preview", ["workspace": "ws", "end": true], gesture: false)
        #expect(tintPreview == nil)
        _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "opacity": 0.4])
        #expect(tint == 0.4)
        #expect(store.background(for: "ws") == nil)
        _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "opacity": .null])
        #expect(tint == nil)
        await #expect(throws: PageError.self) {
            _ = try await call("cmux.settings.backdrop.workspace.set", ["workspace": "ws", "opacity": 2])
        }

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
