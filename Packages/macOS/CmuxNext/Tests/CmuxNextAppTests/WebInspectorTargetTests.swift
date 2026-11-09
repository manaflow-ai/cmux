import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextPages
import Testing
import WebKit

/// Inspect Element and the Developer Tools set (u3971, plans/cmux-next/web-devtools.md) act on
/// any focused web view, not only browser panes: Cmd-Shift-P lists Inspect Element everywhere,
/// disabled with the reason while no web view has focus, and the `devtools.*` set shows when one does.
@MainActor @Suite(.serialized)
struct WebInspectorTargetTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func findsTheWebViewInsideAPane() {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let wrapper = NSView(frame: pane.bounds)
        let webView = WKWebView(frame: wrapper.bounds)
        wrapper.addSubview(webView)
        pane.addSubview(wrapper)
        #expect(WebInspectorTargets.webView(in: pane) === webView)
        wrapper.isHidden = true
        #expect(WebInspectorTargets.webView(in: pane) == nil)
    }

    @Test func findsTheWebViewHoldingTheFirstResponder() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let webView = WKWebView(frame: root.bounds)
        let inner = NSView(frame: webView.bounds)
        webView.addSubview(inner)
        root.addSubview(webView)
        #expect(WebInspectorTargets.webView(containing: inner, within: root) === webView)
        #expect(WebInspectorTargets.webView(containing: inner, within: NSView()) == nil)
        #expect(WebInspectorTargets.webView(containing: NSView(), within: nil) == nil)
    }

    /// A cmux page in WebKit gives its web view; one that refuses probes (a revealed password) gives
    /// no target, and the search does not go on into its web view.
    @Test func aPageViewGivesItsWebViewUnlessItRefusesProbes() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.inspector-target", resource: "inspector-target", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        defer { page.close() }
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        page.frame = pane.bounds
        pane.addSubview(page)
        page.layoutSubtreeIfNeeded()
        guard case .webView(let webView)? = WebInspectorTargets.page(in: pane) else {
            Issue.record("no target in the page's pane"); return
        }
        #expect(webView === page.webKitView)
        #expect(WebInspectorTargets.page(containing: page.webKitView, within: pane) != nil)
        page.refusesProbes = true
        #expect(WebInspectorTargets.page(in: pane) == nil)
        #expect(WebInspectorTargets.page(containing: page.webKitView, within: pane) == nil)
    }

    /// Settings > Advanced > Developer Tools for cmux Pages off: no cmux page is a target, so the
    /// commands are disabled there (a browser tab keeps them).
    @Test func appPagesOffFindsNoPage() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let webView = WKWebView(frame: root.bounds)
        root.addSubview(webView)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = root
        window.makeFirstResponder(webView)
        #expect(WebInspectorTargets().target(in: nil, keyWindow: window) != nil)
        #expect(WebInspectorTargets(appPages: false).target(in: nil, keyWindow: window) == nil)
    }

    @Test func inspectElementIsListedEverywhereAndDisabledWithoutAWebView() {
        let services = Self.services()
        AppActions.bind(services)
        let registry = services.registry
        for id: ActionID in ["inspectBrowserElement", "toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole"] {
            #expect(registry.isAvailable(id, in: []), "\(id)")
            #expect(registry.keyTier(for: id) == .content, "\(id)")
            #expect(!registry.canPerform(id), "\(id)")
            #expect(registry.unavailableReason(for: id) == WebDevToolsLimit.noWebView.message, "\(id)")
        }
        #expect(registry.shortcutKeycaps(for: "inspectBrowserElement") != nil)
    }

    @Test func everyDeveloperToolsCommandIsBoundAndNeedsAWebView() throws {
        let services = Self.services()
        AppActions.bind(services)
        let registry = services.registry
        for command in WebDevToolsCommand.allCases {
            let id = ActionID(rawValue: command.actionID)
            let descriptor = try #require(registry.descriptor(for: id), "\(id)")
            #expect(descriptor.requires == .webViewFocused, "\(id)")
            #expect(registry.isBound(id), "\(id)")
            #expect(!registry.isAvailable(id, in: []), "\(id)")
            #expect(registry.isAvailable(id, in: [.webViewFocused]), "\(id)")
        }
        let catalogIDs = Set(registry.descriptors.map(\.id.rawValue).filter { $0.hasPrefix("devtools.") })
        #expect(catalogIDs == Set(WebDevToolsCommand.allCases.map(\.actionID)))
    }
}
