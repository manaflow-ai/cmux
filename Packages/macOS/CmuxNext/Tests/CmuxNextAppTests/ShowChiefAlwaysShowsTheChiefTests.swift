import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextLayout
import Foundation
import Testing

/// David Beyer, Nov 20: "Show Chief" did not show the Chief unless he went to Home ("fragmented"). Show/Hide Chief
/// (Cmd-I, `home.openChiefDock`) always shows the Chief: in a window with no Home yet it makes the Home in the
/// background and opens the Chief over the workspace the window shows, never a page change to Home; on the Chief's
/// own page (Home) it opens the Chief's conversation (`home.openChief`), not the last group chat or DM.
@MainActor @Suite(.serialized)
struct ShowChiefAlwaysShowsTheChiefTests {
    /// A window's frame with no AppKit: what the Chief panel and a show did, as a stream of events.
    @MainActor final class Frame: WindowDockFrame {
        enum Event: Equatable, Sendable { case show(String), panel }
        var frameWindowID = "win"
        var frameDocks = WindowDocks()
        var frameFocusedWorkspaceID: String? { shown }
        var frameStageWorkspaceID: String?
        var frameShownWorkspaceID: String? { shown }
        var frameMembers: [String] { [home, shown].compactMap { $0 } }
        var frameHome: String? { home }
        var frameChiefPanel = ChiefPanel()
        var frameChiefPanelArm: ContinuousClock.Instant?
        var frameChiefPanelShown: Bool { frameChiefPanel.isShown(stage: shown, home: home) }
        var frameChiefPanelHasKeys = false
        var shown: String?
        var home: String?
        var shows: [String] = []
        let events: AsyncStream<Event>
        private let yield: AsyncStream<Event>.Continuation

        init(shown: String?, home: String?) {
            self.shown = shown
            self.home = home
            (events, yield) = AsyncStream.makeStream()
        }

        func frameChiefPanelLies(toward direction: LayoutDirection) -> Bool { false }
        func frameFocusChiefPanel() { frameChiefPanelHasKeys = true }
        func frameFocusStage(toward direction: LayoutDirection?) { frameChiefPanelHasKeys = false }
        func frameChiefPanelDidChange() { yield.yield(.panel) }
        func frameShow(_ id: String, thisWindow: Bool) {
            shown = id
            shows.append(id)
            yield.yield(.show(id))
        }
        func frameCreateWorkspace(cwd: String?) async -> String? { nil }
        func frameDockWhenReported(_ id: String, at edge: DockEdge) {}
        func frameClaim(_ id: String) {}
        func frameDidChange() {}
        func frameSaveRecord() {}
    }

    /// The app as the dock actions see it: one window, a Home made on request.
    @MainActor final class Host: WindowDockHost {
        let frame: Frame
        var composerFocused = 0
        init(_ frame: Frame) { self.frame = frame }
        func dockFrame(_ invocation: ActionInvocation) -> (any WindowDockFrame)? { frame }
        var dockActiveFrame: (any WindowDockFrame)? { frame }
        func dockFrame(owning id: String) -> (any WindowDockFrame)? { frame }
        func dockTargetWorkspace(_ invocation: ActionInvocation) -> String? { frame.shown }
        func dockPaneWorkspace(_ invocation: ActionInvocation) -> String? { frame.shown }
        func dockMovePane(_ invocation: ActionInvocation, into id: String) -> Bool { false }
        func dockMovePaneToNewWorkspace(_ invocation: ActionInvocation) async -> String? { nil }
        var chiefDockEdge: DockEdge { .right }
        var chiefSidePanelOn: Bool { false }
        var dockFrames: [any WindowDockFrame] { [frame] }
        var chiefDockOpensBeside: Bool { false }
        var chiefHomeIsClassic: Bool { false }
        func chiefHome(in windowID: String) -> String? { frame.home }
        func chiefMakeHome(in windowID: String) async -> String? {
            frame.home = "home"
            return "home"
        }
        func chiefShowHome() -> Bool { false }
        func chiefFocusComposer() { composerFocused += 1 }
        func chiefBringAppForward() -> Bool { false }
    }

    @MainActor final class Count { var value = 0 }

    /// The frame's first event after the action.
    static func first(_ frame: Frame) async -> Frame.Event? {
        for await event in frame.events { return event }
        return nil
    }

    static func registry(_ host: Host) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        WindowDockActions(host: host).bind(into: registry)
        return registry
    }

    /// No Home yet in this window: Cmd-I makes it in the background and the Chief opens over the workspace, which
    /// stays on screen; the page never changes to Home.
    @Test func withNoHomeYetTheChiefOpensOverTheWorkspace() async throws {
        let frame = Frame(shown: "ws-app", home: nil)
        let host = Host(frame)
        let registry = Self.registry(host)
        #expect(registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
        let first = await Self.first(frame)
        #expect(first == .panel, "Cmd-I with no Home did \(String(describing: first)), not open the Chief")
        #expect(frame.shows.isEmpty, "Cmd-I went to \(frame.shows) instead of showing the Chief over the workspace")
        #expect(frame.shown == "ws-app" && frame.frameChiefPanelShown, "the Chief does not show over the workspace")
        #expect(frame.frameChiefPanelHasKeys, "the Chief's message box does not take the keys")
    }

    /// On the Chief's page (Home): Cmd-I opens the Chief's own conversation, wherever the list was.
    @Test func onTheChiefsPageCmdIOpensTheChiefsConversation() {
        let frame = Frame(shown: "home", home: "home")
        let host = Host(frame)
        let registry = Self.registry(host)
        let opened = Count()
        registry.bind("home.openChief") { opened.value += 1 }
        #expect(registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
        #expect(opened.value == 1, "Cmd-I on the Chief's page left the last chat shown, not the Chief's conversation")
        #expect(!frame.frameChiefPanelShown, "the Chief panel showed over the Chief's own page")
    }

    /// A window that shows nothing yet (no workspace) still shows the Chief: its page.
    @Test func withNothingShownCmdIShowsTheChiefsPage() async throws {
        let frame = Frame(shown: nil, home: nil)
        let host = Host(frame)
        let registry = Self.registry(host)
        #expect(registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
        let first = await Self.first(frame)
        #expect(first == .show("home"), "Cmd-I in an empty window did \(String(describing: first))")
        #expect(host.composerFocused == 1)
    }
}
