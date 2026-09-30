import Foundation
import Testing
@testable import CmuxNextBrowser

/// Per-profile permission decisions: defaults, persistence, reset, and
/// which rows Page Info lists.
@MainActor
struct PageInfoPermissionTests {
    private let origin = "https://permission.site"

    @Test func defaultsFollowChrome() {
        #expect(SitePermissionKind.camera.defaultSetting == .ask)
        #expect(SitePermissionKind.javascript.defaultSetting == .allow)
        #expect(SitePermissionKind.popups.defaultSetting == .block)
        #expect(SitePermissionKind.sound.choices == [.allow, .block])
        #expect(SitePermissionKind.notifications.choices == [.ask, .allow, .block])
    }

    @Test func decisionsPersistAndDefaultsClearThem() async {
        let persistence = MemorySitePermissionPersistence()
        let store = SitePermissionStore(profile: .default, persistence: persistence)
        await store.whenLoaded()
        store.set(.block, .camera, for: origin)
        store.set(.allow, .notifications, for: origin)
        #expect(store.setting(.camera, for: origin) == .block)
        #expect(store.changedKinds(for: origin) == [.camera, .notifications])
        store.set(.ask, .notifications, for: origin)
        #expect(store.decision(.notifications, for: origin) == nil)
        await store.flush()
        #expect(await persistence.saved.origins[origin] == [.camera: .block])

        // A new store for the profile (next launch) applies the decision.
        let relaunched = SitePermissionStore(profile: .default, persistence: persistence)
        await relaunched.whenLoaded()
        #expect(relaunched.setting(.camera, for: origin) == .block)
        #expect(relaunched.setting(.camera, for: "https://other.example") == .ask)
    }

    /// A per-site JavaScript block holds in every frame: a blocked site's
    /// frames (its own iframes too) and a blocked origin framed by another
    /// site run no script. It was applied to main-frame navigations only.
    @Test func javaScriptBlockAppliesToSubframes() async {
        let store = SitePermissionStore(profile: .default, persistence: MemorySitePermissionPersistence())
        await store.whenLoaded()
        let blocked = "https://blocked.example", other = "https://other.example"
        store.set(.block, .javascript, for: blocked)
        func allows(_ main: Bool, _ frame: String, _ top: String) -> Bool? {
            WebKitTab.allowsJavaScript(isMainFrame: main, frameOrigin: frame, topOrigin: top, store: store)
        }
        #expect(allows(true, blocked, blocked) == false)
        #expect(allows(true, other, other) == true)
        #expect(allows(false, blocked, other) == false, "a blocked origin framed by another site")
        #expect(allows(false, other, blocked) == false, "any frame of a blocked site")
        #expect(allows(false, other, other) == true)
    }

    @Test func resetClearsEveryDecisionOfTheOrigin() async {
        let persistence = MemorySitePermissionPersistence(SitePermissionSnapshot(origins: [
            origin: [.camera: .allow, .javascript: .block], "https://keep.example": [.location: .block],
        ]))
        let store = SitePermissionStore(profile: .default, persistence: persistence)
        await store.whenLoaded()
        store.reset(origin: origin)
        await store.flush()
        #expect(store.decisions[origin] == nil)
        #expect(await persistence.saved.origins == ["https://keep.example": [.location: .block]])
    }

    @Test func editsBeforeTheFileLoadsWin() async {
        let persistence = MemorySitePermissionPersistence(SitePermissionSnapshot(origins: [origin: [.camera: .allow]]))
        let store = SitePermissionStore(profile: .default, persistence: persistence)
        store.set(.block, .camera, for: origin)
        await store.whenLoaded()
        #expect(store.setting(.camera, for: origin) == .block)
    }

    @Test func fileRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pageinfo-\(UUID().uuidString)/profile.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SitePermissionStore(profile: .default, persistence: FileSitePermissionPersistence(fileURL: url))
        await store.whenLoaded()
        store.set(.block, .microphone, for: origin)
        await store.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"microphone\" : \"block\""))
        let reloaded = SitePermissionStore(profile: .default, persistence: FileSitePermissionPersistence(fileURL: url))
        await reloaded.whenLoaded()
        #expect(reloaded.setting(.microphone, for: origin) == .block)
    }

    @Test func registryKeepsOneStorePerProfile() {
        let registry = SiteSettingsRegistry(persistence: { _ in MemorySitePermissionPersistence() })
        let other = BrowserProfileID(rawValue: UUID())
        #expect(registry.permissions(for: .default) === registry.permissions(for: .default))
        #expect(registry.permissions(for: .default) !== registry.permissions(for: other))
    }

    @Test func rowsShowOnlyChangedRequestedOrUsedPermissions() {
        let all = Set(SitePermissionKind.allCases)
        #expect(PageInfoPermissionList.rows(supported: all, decisions: [:]).isEmpty)

        let rows = PageInfoPermissionList.rows(
            supported: all, decisions: [.javascript: .block], requested: [.camera], inUse: [.microphone],
            changedSinceLoad: [.notifications]
        )
        #expect(rows.map(\.kind) == [.camera, .microphone, .notifications, .javascript])
        #expect(rows.first { $0.kind == .javascript }?.isDefault == false)
        #expect(rows.first { $0.kind == .microphone }?.isInUse == true)
        #expect(PageInfoPermissionList.resettableCount(rows) == 1)
    }

    @Test func unsupportedKindsAreHiddenAndLiveValuesFillGaps() {
        let rows = PageInfoPermissionList.rows(
            supported: [.camera, .location], decisions: [.popups: .allow], live: [.location: .allow, .camera: .ask]
        )
        #expect(rows.map(\.kind) == [.location])
        #expect(rows.first?.setting == .allow)
    }

    @Test func stateTextsFollowChrome() {
        #expect(PageInfoModel.stateText(SitePermissionState(kind: .camera, setting: .allow, isDefault: false)) == "Allowed")
        #expect(PageInfoModel.stateText(SitePermissionState(kind: .javascript, setting: .allow, isDefault: true)) == "Allowed (default)")
        #expect(PageInfoModel.stateText(SitePermissionState(kind: .popups, setting: .block, isDefault: true)) == "Not allowed (default)")
        #expect(PageInfoModel.stateText(SitePermissionState(kind: .sound, setting: .block, isDefault: false)) == "Muted")
        #expect(PageInfoModel.stateText(SitePermissionState(kind: .camera, setting: .ask, isDefault: true)) == "Can ask to use your camera")
        #expect(PageInfoModel.stateText(SitePermissionState(kind: .camera, setting: .allow, isDefault: false, isInUse: true)) == "Using now")
    }
}

/// "About this page" sends the page's address to a search engine: never the
/// fragment or user credentials, which the page keeps on the client (a
/// decryption key in `#...`, `user:pass@`).
@MainActor
struct PageInfoAboutThisPageTests {
    @Test func theSearchCarriesNoFragmentOrCredentials() throws {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://user:secret@share.example/doc/7?view=1#key=abc123")!, security: .secure)
        let url = try #require(model.aboutThisPageURL)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value)
        #expect(query == "About https://share.example/doc/7?view=1")
    }
}
