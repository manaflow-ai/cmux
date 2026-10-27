import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextFocus
import Foundation
import Testing

/// Task 033 of plans/cmux-next/chrome-parity/p01-process.md: in host mode no DevTools key handler asks
/// cmux, so Cmd-Opt-I is decided where every key passes first, the key dispatcher in `sendEvent`. From
/// the hosted page and from its docked DevTools the key runs Toggle Developer Tools before it goes on
/// the wire (the page never gets it first), and two presses send one show and then one close to the
/// host's shim, as Chrome decides DevTools keys in its browser process
/// (chrome/browser/devtools/devtools_window.cc, `DevToolsWindow::PreHandleKeyboardEvent`).
@MainActor @Suite(.serialized) struct DevToolsKeyHostModeTests {
    private static let browser: Int32 = 1

    /// The hosted page reports the keys it left unhandled; DevTools is its own focus target.
    static let focuses: [(name: String, focus: FocusState, facts: KeyRouter.Facts)] = {
        var page = FocusState()
        page.resolved = .browserPage(pane: "pane_page", tab: "tab_page")
        page.context = FocusState.Context(browser: true)
        var devTools = FocusState()
        devTools.resolved = .devTools(pane: "pane_page", tab: "tab_page")
        devTools.context = FocusState.Context(browser: true)
        return [("hosted page", page, KeyRouter.Facts(pageReportsUnhandledKeys: true)), ("DevTools", devTools, KeyRouter.Facts())]
    }()

    @Test func cmdOptionITogglesHostedDevToolsFromThePageAndFromDevTools() throws {
        for (name, focus, facts) in Self.focuses {
            let rig = try HostModeRig()
            defer { rig.close() }
            let router = KeyRouter(registry: rig.registry)
            let context = router.keyContext(for: focus, facts: facts)

            for _ in 0..<2 {
                guard case .run(let candidate) = router.decide(try Self.commandOptionI(), focus: focus, keyWindow: .content, facts: facts) else {
                    Issue.record("Cmd-Opt-I from the \(name) did not run in sendEvent")
                    return
                }
                #expect(candidate.id == "toggleBrowserDeveloperTools", "\(name)")
                router.run(candidate, context: context, window: "window")
            }

            let show = "command \(CEFShimLibrary.DevToolsCommand.show)"
            let close = "command \(CEFShimLibrary.DevToolsCommand.close)"
            #expect(HostKeySpy.log == ["place \(Self.browser)", show, close], "two presses from the \(name)")
        }
    }

    private static func commandOptionI() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                      timestamp: 1, windowNumber: 0, context: nil, characters: "\u{02C6}",
                                      charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
    }

    /// A host-mode tab whose browser exists, and a registry whose Toggle Developer Tools runs the app's
    /// handler path for it (`WebInspector.toggle`).
    @MainActor final class HostModeRig {
        let registry = ActionRegistry.standard()
        let runtime: CEFRuntime
        let tab: CEFTab
        let root: URL

        init() throws {
            HostKeySpy.log = []
            root = FileManager.default.temporaryDirectory.appending(path: "devtools-key-host-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HostKeySpy.symbol), storage: CEFProfileStorage(root: root))
            runtime.hostStart = CEFHostStart(supervisor: NeverAttachingHost())
            // A tab's scheduled work reads the runtime through an unowned reference: it outlives the test.
            _ = Unmanaged.passRetained(runtime)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            runtime.register(tab, browser: DevToolsKeyHostModeTests.browser)
            tab.devToolsController.layout = CEFDevToolsLayout()
            tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            registry.context = [.webViewFocused]
            let tab = tab
            registry.bind("toggleBrowserDeveloperTools", invoke: { _ in WebInspector.toggle(.browser(tab)) })
            HostKeySpy.log = []
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Never attaches: the test drives the key path against the spy shim and never starts Chromium.
@MainActor private final class NeverAttachingHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim: the DevTools placement and commands record in order; every other symbol returns 0.
private nonisolated enum HostKeySpy {
    nonisolated(unsafe) static var log: [String] = []

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let setPlacement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void = {
            browser, _, _, _, _, _ in
            HostKeySpy.log.append("place \(browser)")
        }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { _, command, _, _ in
            HostKeySpy.log.append("command \(command)")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_devtools_set_placement": unsafeBitCast(setPlacement, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
