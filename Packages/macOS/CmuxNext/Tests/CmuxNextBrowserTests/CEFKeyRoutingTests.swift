import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p04-input-062 of plans/cmux-next/chrome-parity/p04-input.md: Chromium's pre-key hook
/// (`CEFRuntime.routeKey`, from `cefKeyCallback`) asks the host's router first what the dispatcher
/// decided for the key in `sendEvent`. A decided key never runs the dispatcher again: a settled one
/// goes to the page with no binding resolved (no focus-mode walk, no extension shortcut lookup), and
/// one whose extension shortcuts the dispatcher did not look up (a key it offered to the page, a
/// cmux page in Chromium) runs its `chrome.commands` shortcut before the page. Only a key that never
/// passed `sendEvent` (a synthetic one) runs the dispatcher, and only once. Chrome decides a browser
/// shortcut once and runs extension commands before the renderer
/// (`BrowserView::PreHandleKeyboardEvent`, chrome/browser/ui/views/frame/browser_view.cc).
@MainActor @Suite(.serialized) struct CEFKeyRoutingTests {
    private static let browser: Int32 = 7

    /// A router that decides like `KeyRouter`: the dispatcher marks every key it examines decided.
    @MainActor final class SpyRouter: BrowserKeyRouting {
        var decided: [ObjectIdentifier: BrowserDecidedKey] = [:]
        /// Keys kept alive so an identity in `decided` never names a freed event.
        private var kept: [NSEvent] = []
        var decidedQuestions = 0
        var dispatches = 0
        var focusModeQuestions = 0
        var unhandledReports = 0
        var handles = false

        func decide(_ event: NSEvent, _ decision: BrowserDecidedKey = .settled) {
            kept.append(event)
            decided[ObjectIdentifier(event)] = decision
        }

        func decidedKey(_ event: NSEvent) -> BrowserDecidedKey {
            decidedQuestions += 1
            return decided[ObjectIdentifier(event)] ?? .undecided
        }

        func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition {
            guard decided[ObjectIdentifier(event)] == nil else { return .passToPage }
            dispatches += 1
            decide(event)
            return handles ? .handledByHost : .passToPage
        }

        func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool {
            focusModeQuestions += 1
            return false
        }

        /// The report that runs a held cmux action (Find held for an offered Cmd-F).
        func browserTab(_ tab: any BrowserTab, unhandledKeyEquivalent event: NSEvent) -> Bool {
            unhandledReports += 1
            return true
        }
    }

    private static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    private static func rig() throws -> (CEFRuntime, CEFTab, SpyRouter) {
        let runtime = try HostRepliesHarness.inProcessRuntime()
        let tab = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        runtime.tabsByBrowser[browser] = tab
        let router = SpyRouter()
        tab.keyRouter = router
        return (runtime, tab, router)
    }

    /// Cmd-T and Option-K the dispatcher decided and settled in `sendEvent`: the page gets them, and
    /// the hook asks one question and resolves nothing.
    @Test func aDecidedKeyResolvesNoBindingInThePreKeyHook() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        for event in [try Self.key("t", [.command], keyCode: 17), try Self.key("k", [.option], keyCode: 40)] {
            router.decide(event)
            #expect(!runtime.routeKey(event, browser: Self.browser), "a decided key was consumed")
        }
        #expect(router.decidedQuestions == 2)
        #expect(router.dispatches == 0, "the dispatcher ran again for a decided key")
        #expect(router.focusModeQuestions == 0, "the focus-mode walk and the extension shortcut lookup ran for a settled key")
        withExtendedLifetime(tab) {}
    }

    /// A Cmd chord that never passed `sendEvent` runs the dispatcher once; Chromium offering it again
    /// finds it decided.
    @Test func aSyntheticKeyRunsTheDispatcherOnce() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        let event = try Self.key("t", [.command], keyCode: 17)
        #expect(!runtime.routeKey(event, browser: Self.browser))
        #expect(!runtime.routeKey(event, browser: Self.browser))
        #expect(router.dispatches == 1, "a synthetic key ran the dispatcher \(router.dispatches) times")
        #expect(router.focusModeQuestions == 1, "only the first offer reached the extension shortcut step")

        let handled = try Self.key("w", [.command], keyCode: 13)
        router.handles = true
        #expect(runtime.routeKey(handled, browser: Self.browser), "the dispatcher's action did not consume the key")
        #expect(router.dispatches == 2)
        withExtendedLifetime(tab) {}
    }

    /// An Option chord the dispatcher never saw skips the dispatcher (no Command or Control) and
    /// still reaches the profile's extension shortcuts.
    @Test func anUndecidedOptionChordReachesTheExtensionShortcutStep() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        #expect(!runtime.routeKey(try Self.key("k", [.option], keyCode: 40), browser: Self.browser))
        #expect(router.dispatches == 0)
        #expect(router.focusModeQuestions == 1)
        withExtendedLifetime(tab) {}
    }

    /// Typing (no Command, Control or Option) is the page's: the hook asks the router nothing.
    @Test func aTypingKeyAsksTheRouterNothing() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        #expect(!runtime.routeKey(try Self.key("a", [], keyCode: 0), browser: Self.browser))
        #expect(!runtime.routeKey(try Self.key("A", [.shift], keyCode: 0), browser: Self.browser))
        #expect(router.decidedQuestions == 0)
        #expect(router.dispatches == 0)
        #expect(router.focusModeQuestions == 0)
        withExtendedLifetime(tab) {}
    }

    /// Cmd-F the dispatcher offered to the page (cmux's Find held for an unhandled report) and
    /// Option-K it passed on, each a `chrome.commands` shortcut of an enabled extension: the hook runs
    /// each shortcut once, before the page, and never runs the dispatcher again. A consumed key gets
    /// no unhandled report, so the held Find never runs. Before, the hook gave every decided key to
    /// the page and these shortcuts never ran. A settled key with the same shortcut runs nothing.
    @Test func anOwedDecidedKeyRunsItsExtensionShortcutOnce() throws {
        KeyRoutingExtensionSpy.runs = []
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(KeyRoutingExtensionSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        let tab = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        runtime.register(tab, browser: Self.browser)
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        let router = SpyRouter()
        tab.keyRouter = router
        let id = KeyRoutingExtensionSpy.extensionID

        let find = try Self.key("f", [.command], keyCode: 3)
        router.decide(find, .extensionShortcutOwed)
        #expect(runtime.routeKey(find, browser: Self.browser), "the extension shortcut did not consume the offered key")
        #expect(KeyRoutingExtensionSpy.runs == ["\(id) find"])

        let optionK = try Self.key("k", [.option], keyCode: 40)
        router.decide(optionK, .extensionShortcutOwed)
        #expect(runtime.routeKey(optionK, browser: Self.browser))
        #expect(KeyRoutingExtensionSpy.runs == ["\(id) find", "\(id) toggle"])

        let settled = try Self.key("f", [.command], keyCode: 3)
        router.decide(settled, .settled)
        #expect(!runtime.routeKey(settled, browser: Self.browser))
        #expect(KeyRoutingExtensionSpy.runs.count == 2, "a settled key ran an extension shortcut")

        #expect(router.dispatches == 0, "the dispatcher ran again for a decided key")
        #expect(router.unhandledReports == 0, "the held cmux action could run")
        withExtendedLifetime(tab) {}
    }
}

/// The shim for ``CEFKeyRoutingTests/anOwedDecidedKeyRunsItsExtensionShortcutOnce()``: one enabled
/// extension whose `chrome.commands` are Cmd-F (`find`) and Option-K (`toggle`), and the commands
/// Chromium was asked to run. Every other function returns 0.
nonisolated enum KeyRoutingExtensionSpy {
    static let extensionID = "abcdefghijklmnopabcdefghijklmnop"
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-in it calls there
    nonisolated(unsafe) static var runs: [String] = []

    static let extensions = #"[{"id":"\#(extensionID)","name":"Shortcuts","enabled":true,"has_action":true}]"#
    /// ui::VKEY_F and ui::VKEY_K with ui::EF_COMMAND_DOWN and ui::EF_ALT_DOWN (ui/events/event_constants.h).
    static let commands = #"[{"extension_id":"\#(extensionID)","name":"find","key_code":70,"modifiers":16},"#
        + #"{"extension_id":"\#(extensionID)","name":"toggle","key_code":75,"modifiers":8}]"#

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let forkAPIVersion: @convention(c) () -> Int32 = { 12 }
        let extList: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in strdup(KeyRoutingExtensionSpy.extensions) }
        let extCommands: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in strdup(KeyRoutingExtensionSpy.commands) }
        let commandRun: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, id, command in
            KeyRoutingExtensionSpy.runs.append("\(id.map { String(cString: $0) } ?? "") \(command.map { String(cString: $0) } ?? "")")
            return 0
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_list": unsafeBitCast(extList, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_commands": unsafeBitCast(extCommands, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_command_run": unsafeBitCast(commandRun, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
