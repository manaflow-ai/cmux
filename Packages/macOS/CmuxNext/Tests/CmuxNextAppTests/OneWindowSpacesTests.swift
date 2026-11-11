import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-11, after an agent's chat showed up in a second window: "Did you open it in a new window? Also We were
/// saying before that we wanted the different windows to be accessible through spaces, and it's essentially all the
/// same window in a way if you want it to be." An agent's or the CLI's open lands in the window the person works in,
/// taking the workspace from another window rather than raising that one; a click on a space brings it here
/// (`space.bringHere`), the current space too when another window also shows it. The real registry, as
/// `GatherWindowsTests`.
@MainActor @Suite(.serialized, .closesItsWindows)
struct OneWindowSpacesTests {
    typealias Gather = GatherWindowsTests

    /// The window the person works in is where an open lands, never another one.
    @Test func anOpenLandsInTheWindowThePersonWorksIn() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let here = try Gather.open(["k0"], services), there = try Gather.open(["k1"], services)
        services.windows.didActivate(there)
        services.windows.didActivate(here)
        #expect(services.windows.registry.value.currentOpen(preferring: services.windows.active?.state.id) == here.state.id)
    }

    /// An incognito window is never where a normal open lands: the most recent normal window is.
    @Test func anOpenNeverLandsInAnIncognitoWindow() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let normal = try Gather.open(["k0"], services), incognito = try Gather.open(["k1"], services, incognito: true)
        services.windows.didActivate(normal)
        services.windows.didActivate(incognito)
        #expect(services.windows.registry.value.currentOpen(preferring: services.windows.active?.state.id) == normal.state.id)
    }

    /// A tab an agent opens in a workspace another window lists (`agent.openSessionTab` reveals it `here`): this window
    /// takes the workspace (the other window, emptied, closes), so nothing else comes forward.
    @Test func theCurrentWindowTakesAnOpenedTabsWorkspace() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let here = try Gather.open(["k0"], services), there = try Gather.open(["k1"], services)
        services.windows.didActivate(here)

        let shown = services.windows.reveal(workspaceID: "k1", here: true)

        let registry = services.windows.registry.value
        #expect(shown === here, "another window showed it")
        #expect(registry.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k1"])
        #expect(registry.window(there.state.id) == nil, "the emptied window stayed open")
    }

    /// #41499 F2: a workspace's session-only browser tabs (`localBrowserTabs`, a daemon without frontend browser tabs)
    /// live in its window's state. When the current window takes the workspace, they go with it: left behind they would
    /// be stranded, and dropped when the emptied window closes.
    @Test func aTakenWorkspaceBringsItsLocalBrowserTabs() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let here = try Gather.open(["k0"], services), there = try Gather.open(["k1"], services)
        services.windows.didActivate(here)
        let pane = try #require(services.workspace(id: "k1")?.screens.first?.panes.first?.id)
        let local = LocalBrowserTab.make(url: URL(string: "https://example.com"))
        there.state.localBrowserTabs[pane] = [local]

        _ = services.windows.reveal(workspaceID: "k1", here: true)

        #expect(services.windows.registry.value.owner(of: "k1") == here.state.id)
        #expect(here.state.localBrowserTabs[pane] == [local], "the workspace's local tab did not come with it")
        #expect(there.state.localBrowserTabs[pane].isEmpty, "the local tab stayed in the window it left")
    }

    /// Pane ids repeat across machines: when this window already keeps local tabs under the same pane id, the tabs
    /// cannot move, so the workspace stays where it is with its tabs (shown there, as before).
    @Test func aWorkspaceWhoseLocalTabsCannotMoveStaysPut() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let here = try Gather.open(["k0"], services), there = try Gather.open(["k1"], services)
        services.windows.didActivate(here)
        let pane = try #require(services.workspace(id: "k1")?.screens.first?.panes.first?.id)
        let theirs = LocalBrowserTab.make(url: nil), ours = LocalBrowserTab.make(url: nil)
        there.state.localBrowserTabs[pane] = [theirs]
        here.state.localBrowserTabs[pane] = [ours]

        let shown = services.windows.reveal(workspaceID: "k1", here: true)

        #expect(shown === there)
        #expect(services.windows.registry.value.owner(of: "k1") == there.state.id)
        #expect(there.state.localBrowserTabs[pane] == [theirs] && here.state.localBrowserTabs[pane] == [ours])
    }

    /// Incognito and normal content never mix: an incognito window's workspace stays in its window.
    @Test func anIncognitoWorkspaceStaysInItsWindow() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let here = try Gather.open(["k0"], services), incognito = try Gather.open(["k1"], services, incognito: true)
        services.windows.didActivate(here)

        _ = services.windows.reveal(workspaceID: "k1", here: true)

        let registry = services.windows.registry.value
        #expect(registry.window(incognito.state.id)?.workspaceIDs == ["k1"])
        #expect(registry.window(here.state.id)?.workspaceIDs == ["k0"])
    }

    /// The screenshot's case: two windows on the same space ("Default, in another window"). A click on the current
    /// space's dot brings the other window's workspaces of that space here, and that window closes.
    @Test func theCurrentSpaceComesTogetherFromAnotherWindow() throws {
        let services = try Gather.services()
        defer { Gather.closeAll(services) }
        let here = try Gather.open(["k0"], services), there = try Gather.open(["k1"], services)
        services.windows.select("k0", in: here.state)
        services.windows.select("k1", in: there.state)
        #expect(here.state.profileID == there.state.profileID)

        try services.windows.bringSpace(here.state.profileID, into: here.state)

        let registry = services.windows.registry.value
        #expect(registry.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k1"])
        #expect(registry.window(there.state.id) == nil, "the other window on the same space stayed")
        #expect(here.state.workspaceID == "k0", "the window lost its selection")
    }
}
