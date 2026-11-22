import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The Dictation key (Globe-D, the 🎤 key) and Edit ▸ Start Dictation in an agent pane start the pane's
/// own dictation, the waveform inside the composer, not macOS's black overlay that AppKit placed
/// over the composer's corner. The `agent.systemDictation` Debug toggle brings macOS's back.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneDictationKeyTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Debug Settings as the app holds them, with `agent.systemDictation` `on` (nil: never set).
    private static func tunables(_ on: Bool?) -> TunableStore {
        let store = TunableStore()
        store.register(AgentPaneTunables.all)
        store.activate(file: nil)
        if let on { store.set(AgentPaneTunables.systemDictation.key, .bool(on)) }
        return store
    }

    /// Where each Start Dictation from the pane's web view went.
    private final class Routes {
        var pane = 0
        var system = 0
    }

    /// An agent page in a pane's content host, its Start Dictation routes recorded.
    private func page(systemDictation: Bool?) throws -> (AgentPaneView, Routes, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dictation-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.addSubview(view)
        let routes = Routes()
        view.dictationKey = AgentPaneDictationKey(tunables: Self.tunables(systemDictation),
                                                  pane: { _ in routes.pane += 1 },
                                                  system: { _ in routes.system += 1 })
        return (view, routes, directory)
    }

    /// Start Dictation as AppKit sends it: up the responder chain from the focused web view.
    private func startDictation(from view: AgentPaneView) -> Bool {
        view.webView.tryToPerform(AgentPaneDictationKey.action, with: nil)
    }

    @Test func theDictationKeyStartsThePanesDictationNotMacOSs() throws {
        let (view, routes, directory) = try page(systemDictation: nil)
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        #expect(startDictation(from: view), "Start Dictation from the agent page went past the pane to NSApplication")
        #expect(routes.pane == 1, "the Dictation key did not start the pane's dictation")
        #expect(routes.system == 0, "the Dictation key also started macOS's dictation overlay")
        #expect(startDictation(from: view))
        #expect(routes.pane == 2, "a second press did not reach the pane's dictation to finish it")
        #expect(routes.system == 0)
    }

    @Test func theDebugToggleGivesTheKeyBackToMacOS() throws {
        let (view, routes, directory) = try page(systemDictation: true)
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        #expect(startDictation(from: view))
        #expect(routes.system == 1, "with agent.systemDictation on, the Dictation key did not start macOS's dictation")
        #expect(routes.pane == 0, "with agent.systemDictation on, the Dictation key still started the pane's dictation")
    }

    /// The pane's content host in a window of its own (the cmux window).
    private func window(holding view: AgentPaneView) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = try #require(view.superview)
        return window
    }

    /// AppKit adds Edit ▸ Start Dictation with NSApplication as its target (Globe-D is its key
    /// equivalent), so the key calls NSApplication's `startDictation:` and no responder sees it:
    /// the app's NSApplication asks the pane whose page has the keyboard to take it.
    @Test func theDictationKeyAtNSApplicationStartsThePanesDictation() throws {
        let (view, routes, directory) = try page(systemDictation: nil)
        let window = try window(holding: view)
        defer { view.close(); window.close(); try? FileManager.default.removeItem(at: directory) }
        try #require(window.makeFirstResponder(view.webView))
        #expect(AgentPaneView.takeStartDictation(in: window, sender: nil),
                "Start Dictation at NSApplication with the agent page's keyboard went to macOS's dictation overlay")
        #expect(routes.pane == 1, "the Dictation key did not start the pane's dictation")
        #expect(AgentPaneView.takeStartDictation(in: window, sender: nil))
        #expect(routes.pane == 2, "a second press did not reach the pane's dictation to finish it")
        #expect(routes.system == 0)
    }

    /// A Chromium agent page draws in a child window over the pane and takes key itself; the key
    /// still starts the pane's dictation.
    @Test func theDictationKeyFromTheChromiumPageWindowStartsThePanesDictation() throws {
        let (view, routes, directory) = try page(systemDictation: nil)
        let window = try window(holding: view)
        let pageWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        defer { view.close(); pageWindow.close(); window.close(); try? FileManager.default.removeItem(at: directory) }
        window.addChildWindow(pageWindow, ordered: .above)
        view.dictationKey.pageWindow = { _ in pageWindow }
        let chromiumView = NSTextView(frame: pageWindow.contentLayoutRect)
        pageWindow.contentView = chromiumView
        try #require(pageWindow.makeFirstResponder(chromiumView))
        #expect(AgentPaneView.takeStartDictation(in: pageWindow, sender: nil),
                "Start Dictation from the Chromium agent page went to macOS's dictation overlay")
        #expect(routes.pane == 1, "the Dictation key in the Chromium page did not start the pane's dictation")
        #expect(routes.system == 0)
    }

    @Test func theDebugToggleLeavesTheKeyToMacOSAtNSApplication() throws {
        let (view, routes, directory) = try page(systemDictation: true)
        let window = try window(holding: view)
        defer { view.close(); window.close(); try? FileManager.default.removeItem(at: directory) }
        try #require(window.makeFirstResponder(view.webView))
        #expect(!AgentPaneView.takeStartDictation(in: window, sender: nil),
                "with agent.systemDictation on, the pane kept the Dictation key from macOS")
        #expect(routes.pane == 0)
    }

    @Test func otherWindowsKeepMacOSsDictation() throws {
        let (view, routes, directory) = try page(systemDictation: nil)
        let paneWindow = try window(holding: view)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { view.close(); other.close(); paneWindow.close(); try? FileManager.default.removeItem(at: directory) }
        let text = NSTextView(frame: other.contentLayoutRect)
        other.contentView = text
        try #require(other.makeFirstResponder(text))
        #expect(!AgentPaneView.takeStartDictation(in: other, sender: nil), "a text view outside agent panes lost macOS's dictation")
        #expect(!AgentPaneView.takeStartDictation(in: nil, sender: nil))
        #expect(routes.pane == 0)
    }

    @Test func theToggleIsADebugSettingOffByDefault() {
        #expect(AgentPaneTunables.systemDictation.key == "agent.systemDictation")
        #expect(AgentPaneTunables.systemDictation.defaultValue == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.systemDictation" })
    }
}
