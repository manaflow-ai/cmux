import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// A Page Info decision taken while none of the profile's Chromium pages was open (an extension's
/// `browser.site.javascript.set`, or Page Info in a WebKit tab) reached Chromium only at the next
/// commit of that origin, after its first load had run JavaScript. A window's request context now
/// gets the profile's decisions before its first page (`cmux_shim_set_context_content_setting`), and a
/// new decision reaches every context of the profile that has a window, page open or not.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFSiteDecisionPushTests {
    @Test func aDecisionMapsAsPageInfoDoes() {
        #expect(CEFContentSetting.forDecision(.javascript, .block) == .block)
        #expect(CEFContentSetting.forDecision(.javascript, .allow) == .default, "the kind's default clears Chromium's exception")
        #expect(CEFContentSetting.forDecision(.automaticDownloads, .block) == nil, "automatic downloads stay with cmux's gate")
    }

    @Test func aNewWindowsContextGetsTheStoresDecisionsBeforeItsFirstPage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-site-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        SiteSpyShim.calls = []
        let runtime = CEFRuntime(shim: try SiteSpyShim.library(), storage: CEFProfileStorage(root: root))
        SiteSpyShim.runtimes.append(runtime)
        let store = runtime.stores.siteSettings.permissions(for: .default)
        await store.whenLoaded()
        store.set(.block, .javascript, for: "https://news.test")
        store.set(.block, .automaticDownloads, for: "https://news.test")

        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = CEFPaneHost(key: key, runtime: runtime)
        runtime.hosts[key] = host
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.add(tab)
        host.ensureCreated(tab)

        let context = runtime.contextKey(for: key)
        #expect(SiteSpyShim.calls == [
            .setting(context: context, url: "https://news.test", type: "javascript", value: CEFContentSetting.block.rawValue),
            .createWindow(context: context),
        ], "the context must hold the block before the window's first page: \(SiteSpyShim.calls)")

        // A later decision reaches that context with no page of the origin open.
        SiteSpyShim.calls = []
        runtime.state = .ready
        runtime.pushSiteDecision(.javascript, .allow, origin: "https://other.test", profile: .default)
        #expect(SiteSpyShim.calls == [.setting(context: context, url: "https://other.test", type: "javascript", value: CEFContentSetting.default.rawValue)])
        // Another profile's contexts are not touched.
        SiteSpyShim.calls = []
        runtime.pushSiteDecision(.javascript, .block, origin: "https://news.test", profile: BrowserProfileID(rawValue: "work"))
        #expect(SiteSpyShim.calls.isEmpty)
    }
}

/// Stand-in shim: records `cmux_shim_set_context_content_setting` and `cmux_shim_create_window` in
/// order; every other function does nothing.
private nonisolated enum SiteSpyShim {
    enum Call: Equatable {
        case setting(context: String, url: String, type: String, value: Int32)
        case createWindow(context: String)
    }
    nonisolated(unsafe) static var calls: [Call] = [] // test-only, main thread (the suite is serialized)
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, context in
            SiteSpyShim.calls.append(.createWindow(context: context.map { String(cString: $0) } ?? ""))
            return 1
        }
        let setting: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = { context, url, type, value in
            let text = { (p: UnsafePointer<CChar>?) in p.map { String(cString: $0) } ?? "" }
            SiteSpyShim.calls.append(.setting(context: text(context), url: text(url), type: text(type), value: value))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_context_content_setting": unsafeBitCast(setting, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
