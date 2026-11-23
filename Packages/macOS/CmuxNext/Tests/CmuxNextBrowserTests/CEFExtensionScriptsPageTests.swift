@testable import CmuxNextBrowser
import Foundation
import Testing

/// Which hidden pages stay awake for an extension (`CEFExtensionStores.scriptsPage(at:profile:)`): a port
/// disconnect that an MV3 extension's stopped service worker sends to a frozen page never reaches it, so a
/// page that an enabled MV3 extension can script is not frozen (Bitwarden's passkey scripts, user
/// 2026-11-17). An MV2 background page (the built-in uBlock Origin) does not stop, so it keeps no page awake.
@MainActor @Suite(.serialized) struct CEFExtensionScriptsPageTests {
    /// One installed extension: its manifest (nil: no folder), version, and state.
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var manifest: String?
        var manifestVersion = 3
        var enabled = true
        var terminated = false
        var url = "https://github.com/sessions/sudo"
        var scripts: Bool
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "MV3, all sites", manifest: #"{"manifest_version": 3, "host_permissions": ["<all_urls>"]}"#, scripts: true),
        Case(name: "MV3, content script on every https site",
             manifest: #"{"manifest_version": 3, "content_scripts": [{"matches": ["https://*/*"], "js": ["c.js"]}]}"#, scripts: true),
        Case(name: "MV3, this site", manifest: #"{"manifest_version": 3, "host_permissions": ["https://github.com/*"]}"#, scripts: true),
        Case(name: "MV3, another site", manifest: #"{"manifest_version": 3, "host_permissions": ["https://example.com/*"]}"#, scripts: false),
        Case(name: "MV3, only when clicked", manifest: #"{"manifest_version": 3, "permissions": ["activeTab"]}"#, scripts: false),
        Case(name: "MV3, manifest not read", manifest: nil, scripts: true),
        Case(name: "MV2 background page, all sites", manifest: #"{"manifest_version": 2, "permissions": ["<all_urls>"]}"#,
             manifestVersion: 2, scripts: false),
        Case(name: "MV3 disabled", manifest: #"{"manifest_version": 3, "host_permissions": ["<all_urls>"]}"#, enabled: false, scripts: false),
        Case(name: "MV3 crashed", manifest: #"{"manifest_version": 3, "host_permissions": ["<all_urls>"]}"#, terminated: true, scripts: false),
        Case(name: "a file page", manifest: #"{"manifest_version": 3, "host_permissions": ["<all_urls>"]}"#,
             url: "file:///Users/me/a.html", scripts: false),
        Case(name: "about:blank", manifest: #"{"manifest_version": 3, "host_permissions": ["<all_urls>"]}"#, url: "about:blank", scripts: false),
    ]

    @Test(arguments: cases)
    func anExtensionKeepsAPageAwakeOnlyWhenItsWorkerCanScriptIt(_ item: Case) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-ext-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        var path = ""
        if let manifest = item.manifest {
            let folder = root.appending(path: "ext/1.0_0", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
            path = folder.path
        }
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root.appending(path: "profiles", directoryHint: .isDirectory)))
        let backend = MockExtensionBackend()
        backend.extensions = [BrowserExtensionInfo(id: "abcdefghijklmnopabcdefghijklmnop", name: "Vault", manifestVersion: item.manifestVersion,
                                                   isEnabled: item.enabled, isTerminated: item.terminated, path: path)]
        let stores = CEFExtensionStores(runtime: runtime, makeBackend: { _ in backend })
        #expect(stores.scriptsPage(at: URL(string: item.url), profile: .default) == item.scripts)
        // A second ask reads nothing again: not the extension list, not the manifest. A page that is not
        // on the web never reads the list.
        #expect(stores.scriptsPage(at: URL(string: item.url), profile: .default) == item.scripts)
        let web = ["http", "https"].contains(URL(string: item.url)?.scheme ?? "")
        #expect(backend.snapshots == (web ? 1 : 0))
    }

    /// The answer is kept for each site, and dropped when the extension list changes: a page that an
    /// extension kept awake can freeze again once the person disables the extension.
    @Test func aDisabledExtensionStopsKeepingThePageAwake() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-ext-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "ext/1.0_0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "host_permissions": ["<all_urls>"]}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root.appending(path: "profiles", directoryHint: .isDirectory)))
        let backend = MockExtensionBackend()
        let vault = BrowserExtensionInfo(id: "abcdefghijklmnopabcdefghijklmnop", name: "Vault", manifestVersion: 3,
                                         isEnabled: true, isTerminated: false, path: folder.path)
        backend.extensions = [vault]
        let stores = CEFExtensionStores(runtime: runtime, makeBackend: { _ in backend })
        let page = URL(string: "https://github.com/sessions/sudo")
        #expect(stores.scriptsPage(at: page, profile: .default))
        #expect(stores.scriptsPage(at: URL(string: "https://GitHub.com/login"), profile: .default))

        var off = vault
        off.isEnabled = false
        backend.extensions = [off]
        stores.refreshAll()
        #expect(!stores.scriptsPage(at: page, profile: .default))
    }

    @Test func aProfileWithNoExtensionFreezesItsPages() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-ext-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        let stores = CEFExtensionStores(runtime: runtime, makeBackend: { _ in MockExtensionBackend() })
        #expect(!stores.scriptsPage(at: URL(string: "https://github.com/"), profile: .default))
    }
}
