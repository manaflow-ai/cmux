import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// Hidden and occluded pages run no loops (p03-rendering-120, feature `hiddenPageLoops`): the host
/// tells the document `cmuxTheme.visibility(shown)` at each new document and each change of whether
/// a person can see it (the engine's visibility and the tab's node, occlusion included), once per
/// change, and nothing while the feature is off.
@MainActor @Suite(.serialized)
struct PageHiddenLoopsTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-hidden-loops", resource: "page-hidden-loops", processGroup: .viewer, namespaces: [])
    private let window: NSWindow
    /// The tab's content view: hiding it hides the page, as a pane hides a tab.
    private let tab: NSView
    /// The tab's node under its window's: the window's occlusion reaches the page through it.
    private let windowNode = VisibilityNode(root: "window", own: .visible)
    private let tabNode: VisibilityNode

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hidden-loops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        tab = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(tab)
        tabNode = VisibilityNode("tab", own: .visible, parent: windowNode)
    }

    private func finish(_ view: PageWebView) {
        view.close()
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// A loaded WebKit page in the tab, following the tab's node, whose scripts go to `bridge`.
    private func loadedView(_ bridge: LoopScriptBridge) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        view.frame = tab.bounds
        tab.addSubview(view)
        view.followAppearance(DesignSettings.shared.signals, node: tabNode)
        view.loaded = true
        view.scriptTarget.bridge = bridge
        return view
    }

    private static let shown = PageWebView.loopVisibilityScript(shown: true)
    private static let hidden = PageWebView.loopVisibilityScript(shown: false)

    @Test func theFeatureOffTellsThePageNothing() throws {
        let bridge = LoopScriptBridge()
        let view = try loadedView(bridge)
        defer { finish(view) }
        tabNode.set(.hidden)
        tabNode.set(.visible)
        windowNode.set(.occluded)
        tab.isHidden = true
        tab.isHidden = false
        view.documentFinished()
        #expect(bridge.loopScripts.isEmpty, "told \(bridge.loopScripts)")
    }

    @Test func aShownPageIsToldOnceAndEachChangeOnce() throws {
        let bridge = LoopScriptBridge()
        let view = try loadedView(bridge)
        defer { finish(view) }
        view.stopLoopsWhileHidden()
        #expect(bridge.loopScripts == [Self.shown])

        // Its window is covered by another window (the occlusion family): hidden, though the engine shows it.
        windowNode.set(.occluded)
        windowNode.set(.visible)
        // Another tab takes the pane: hidden once, though the node and the view both say so.
        tab.isHidden = true
        tabNode.set(.hidden)
        tabNode.set(.visible)
        tab.isHidden = false
        #expect(bridge.loopScripts == [Self.shown, Self.hidden, Self.shown, Self.hidden, Self.shown])
    }

    @Test func aNewDocumentIsToldAgain() throws {
        let bridge = LoopScriptBridge()
        let view = try loadedView(bridge)
        defer { finish(view) }
        view.stopLoopsWhileHidden()
        windowNode.set(.occluded)
        view.documentFinished()
        #expect(bridge.loopScripts == [Self.shown, Self.hidden, Self.hidden])
    }

    @Test func aPageInAWindowThatDrawsCoveredWindowsKeepsItsLoopsWhenOccluded() {
        let node = VisibilityNode(root: "window", own: .occluded)
        #expect(!PageWebView.nodeRunsLoops(node, drawsWhenOccluded: false))
        #expect(PageWebView.nodeRunsLoops(node, drawsWhenOccluded: true))
        node.set(.hidden)
        #expect(!PageWebView.nodeRunsLoops(node, drawsWhenOccluded: true))
    }

    @Test func theHostTurnsItOnForEveryPageItOpens() throws {
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never)
        host.stopsHiddenPageLoops = true
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer {
            host.close(view)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(view.loopVisibility.enabled)
    }
}

/// A bridge that records each script instead of running it.
@MainActor
private final class LoopScriptBridge: PageHostBridge {
    let engine = PageHostEngine.webKit
    var scripts: [String] = []
    /// The loop visibility scripts, in order.
    var loopScripts: [String] { scripts.filter { $0.contains("cmuxTheme.visibility(") } }

    func install(_ handler: @escaping PageHostHandler) {}
    func evaluate(_ script: String) { scripts.append(script) }
    func uninstall() {}
}
