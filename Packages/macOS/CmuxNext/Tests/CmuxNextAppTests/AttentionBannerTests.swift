import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextSettings
import Foundation
import Testing
import UserNotifications

/// The system banner for a tab an agent marked (tab-attention-v1): one per request, none for marks
/// made before launch, withdrawn when the mark clears, and its Show (or a click) goes to the tab
/// through the one shared Go to; posting it moves nothing.
@MainActor @Suite(.serialized)
struct AttentionBannerTests {
    private static func item(_ tab: String, at: UInt64, reason: String = "Log in to GitHub") -> AgentPaneAttentionTabs.Item {
        AgentPaneAttentionTabs.Item(tabId: tab, reason: reason, workspaceTitle: "cmux next", tabTitle: "GitHub", atMs: at)
    }

    @Test func aBannerPostsPerNewRequestAndClearsWithTheMark() {
        let login = Self.item("tab_1", at: 1_000)
        #expect(AttentionBannerLifecycle.attentionChanges(previous: nil, current: [login]) == ([], []),
                "a mark made before launch posts nothing")
        #expect(AttentionBannerLifecycle.attentionChanges(previous: [], current: [login]) == ([login], []))
        #expect(AttentionBannerLifecycle.attentionChanges(previous: [login], current: [login]) == ([], []),
                "the same request never posts twice")
        let again = Self.item("tab_1", at: 2_000, reason: "Approve the scopes")
        let replaced = AttentionBannerLifecycle.attentionChanges(previous: [login], current: [again])
        #expect(replaced.post == [again], "a new request on the tab posts again")
        #expect(replaced.withdraw == [AttentionBannerLifecycle.attentionBannerID(login)])
        #expect(AttentionBannerLifecycle.attentionChanges(previous: [again], current: []).withdraw
            == [AttentionBannerLifecycle.attentionBannerID(again)], "a cleared mark takes its banner back")
    }

    @Test func theBannerNamesItsTabAndNothingElse() {
        let id = AttentionBannerLifecycle.attentionBannerID(Self.item("tab_0f3c", at: 42))
        #expect(id == "cmux-attention.42.tab_0f3c")
        #expect(AttentionBannerLifecycle.attentionTab(banner: id) == "tab_0f3c")
        for other in ["cmux-notification-7", "cmux-attention.", "cmux-attention.x.tab_1", "cmux-attention.42.", "attention.42.tab_1"] {
            #expect(AttentionBannerLifecycle.attentionTab(banner: other) == nil, "\(other)")
        }
    }

    @Test func showGoesToTheMarkedTabThroughGoToOnlyForItsOwnRequest() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let shared = services.attentionTabs
        let (items, onOpen) = (shared.items, shared.onOpen)
        defer { shared.items = items; shared.onOpen = onOpen }
        var shown: [String] = []
        shared.onOpen = { id in shown.append(id); return true }
        let key = AttentionTabsWatch.key(machine: "local", tab: "tab_1")
        let first = Self.item(key, at: 1_000)
        shared.items = [first]
        let service = services.notifications
        service.desktopPostingEnabled = false
        service.attentionMarksChanged([])
        service.attentionMarksChanged(shared.items)
        #expect(shown.isEmpty, "a mark and its banner move nothing")
        let banner = AttentionBannerLifecycle.attentionBannerID(first)
        #expect(service.attentionBanners.isEmpty, "suppressed posting must not authorize a banner click")
        service.attentionBanners.insert(banner) // A delivered banner; posting remains disabled in this routing test.
        #expect(AttentionBannerLifecycle.attentionTab(banner: banner) == key, "the banner names the machine-qualified key")
        #expect(service.showAttention(banner: banner))
        #expect(shown == [key])
        // A newer request on the same tab replaces the banner's: the old banner opens nothing.
        shared.items = [Self.item(key, at: 2_000, reason: "Approve the scopes")]
        #expect(service.showAttention(banner: banner), "the banner is still the attention kind")
        #expect(shown == [key], "a replaced request's banner went to the tab")
        // A cleared mark, or a banner from an earlier launch, opens nothing either.
        shared.items = []
        #expect(service.showAttention(banner: AttentionBannerLifecycle.attentionBannerID(Self.item(key, at: 2_000))))
        #expect(shown == [key], "a cleared mark's banner went to the tab")
        #expect(!service.showAttention(banner: "cmux-notification-3"), "other banners keep their own path")
    }

    /// A banner left in Notification Center by an earlier launch, whose request is still the tab's
    /// live mark after the restart: this launch posted nothing for it, so its Show opens nothing.
    @Test func anEarlierLaunchsBannerOpensNothingEvenWhileItsMarkIsLive() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let shared = services.attentionTabs
        let (items, onOpen) = (shared.items, shared.onOpen)
        defer { shared.items = items; shared.onOpen = onOpen }
        var shown: [String] = []
        shared.onOpen = { id in shown.append(id); return true }
        let live = Self.item(AttentionTabsWatch.key(machine: "local", tab: "tab_1"), at: 1_000)
        shared.items = [live]
        let restarted = services.notifications
        restarted.desktopPostingEnabled = false
        restarted.attentionMarksChanged(shared.items)
        #expect(restarted.showAttention(banner: AttentionBannerLifecycle.attentionBannerID(live)))
        #expect(shown.isEmpty, "an earlier launch's banner went to the tab")
    }

    /// Tabs on this Mac and on an SSH machine share an id (a forked machine keeps its tab ids),
    /// in workspaces of their own. Muting the SSH machine's workspace silences only its tab's
    /// banner: each row's key sends the policy to the tab on its own machine.
    @Test func theBannerReadsMutedOnTheRowsOwnMachine() throws {
        let previousAttention = DesignSettings.shared.attention
        defer { DesignSettings.shared.attention = previousAttention }
        DesignSettings.shared.attention = AttentionSettings()
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-attention-banner-remote-unused")),
                                    environment: { [:] })
        services.machines.add(ssh)
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "GitHub")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        func marked(_ store: DaemonStore, _ snapshot: WorkspaceSnapshot) throws -> (WorkspaceModel, TabModel) {
            store.apply(snapshot: DaemonTree(workspaces: [snapshot]))
            let workspace = try #require(store.workspaces.first)
            let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
            tab.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Log in to GitHub", atMs: 1_000)), progress: nil)
            return (workspace, tab)
        }
        let (hereWorkspace, hereTab) = try marked(services.daemon.store, WorkspaceSnapshot(id: 1, key: nil, name: "here", screens: [screen]))
        let (labWorkspace, labTab) = try marked(ssh.daemon.store, WorkspaceSnapshot(id: 1, key: nil, name: "lab", screens: [screen]))
        #expect(hereTab.id == labTab.id && hereWorkspace.id == labWorkspace.id)
        let items = AttentionTabsWatch.items(in: [(hereWorkspace, machine: "local"), (labWorkspace, machine: ssh.machineID)])
        let here = try #require(items.first { $0.tabId == AttentionTabsWatch.key(machine: "local", tab: hereTab.id, atMs: 1_000) })
        let lab = try #require(items.first { $0.tabId == AttentionTabsWatch.key(machine: ssh.machineID, tab: labTab.id, atMs: 1_000) })
        let notifications = services.notifications
        notifications.preferences.mutedWorkspaces = [NotificationWorkspaceKey.qualified(machine: ssh.machineID, workspace: labWorkspace.id)]
        #expect(notifications.attentionArrival(lab).workspaceMuted, "the SSH machine's muted workspace did not silence its tab's banner")
        #expect(!notifications.attentionArrival(here).workspaceMuted, "muting the SSH workspace silenced this Mac's tab")
        notifications.preferences.mutedWorkspaces = [hereWorkspace.id] // legacy local key remains readable
        #expect(notifications.attentionArrival(here).workspaceMuted)
        #expect(!notifications.attentionArrival(lab).workspaceMuted, "muting this Mac's workspace silenced the SSH machine's tab")
        let remoteKey = NotificationWorkspaceKey.qualified(machine: ssh.machineID, workspace: labWorkspace.id)
        #expect(notifications.attentionArrival(lab).soundScope.workspace == remoteKey,
                "sound rules were not qualified by machine")
        #expect(!NotificationPolicy(prefs: notifications.preferences).decide(notifications.attentionArrival(here)).desktop,
                "a muted workspace's tab still posts a banner")
        #expect(notifications.attentionMarks(for: hereWorkspace).isEmpty)
        #expect(!notifications.attentionMarks(for: labWorkspace).isEmpty, "legacy local mute hid the remote ring")
        notifications.preferences.mutedWorkspaces = [remoteKey]
        #expect(NotificationWorkspaceKey.workspaceIDs([hereWorkspace.id], machine: ssh.machineID, localMachine: "local").isEmpty)
        #expect(NotificationWorkspaceKey.workspaceIDs([remoteKey], machine: ssh.machineID, localMachine: "local") == [labWorkspace.id])
        #expect(notifications.attentionMarks(for: labWorkspace).isEmpty)
        #expect(!notifications.attentionMarks(for: hereWorkspace).isEmpty, "remote mute hid the local ring")
        notifications.preferences.mutedWorkspaces = []
        notifications.preferences.sounds.events[.needsInput] = "Ping"
        notifications.preferences.sounds.workspaces[hereWorkspace.id] = NotificationSoundRule(sound: "Hero")
        let hereScope = notifications.attentionArrival(here).soundScope
        let labScope = notifications.attentionArrival(lab).soundScope
        #expect(notifications.preferences.sounds.choice(for: .needsInput, in: hereScope, fallback: "default")?.name == "Hero")
        #expect(notifications.preferences.sounds.choice(for: .needsInput, in: labScope, fallback: "default")?.name == "Ping",
                "a legacy local sound rule affected the cloned remote workspace")
        notifications.preferences.sounds.workspaces[remoteKey] = NotificationSoundRule(sound: "Basso", volume: 0.25)
        #expect(notifications.preferences.sounds.choice(for: .needsInput, in: labScope, fallback: "default")?.name == "Basso")
        #expect(notifications.preferences.sounds.choice(for: .needsInput, in: labScope, fallback: "default")?.volume == 0.25)
        #expect(notifications.preferences.sounds.choice(for: .needsInput, in: hereScope, fallback: "default")?.name == "Hero")

        notifications.preferences.desktop = .always
        notifications.preferences.suppressWhileTypingSeconds = 60
        let now = ContinuousClock.now
        notifications.recordTyping(tabID: hereTab.id, onMachine: "local", at: now)
        let recentLocal = notifications.attentionArrival(here)
        let untouchedRemote = notifications.attentionArrival(lab)
        #expect(recentLocal.typedAgo != nil)
        #expect(untouchedRemote.typedAgo == nil, "local typing leaked onto the same-id remote tab")
        let policy = NotificationPolicy(prefs: notifications.preferences)
        #expect(!policy.decide(recentLocal).desktop && policy.decide(recentLocal).sound == nil,
                "attention ignored Quiet After Typing")
        #expect(policy.decide(untouchedRemote).desktop)
        notifications.recordTyping(tabID: hereTab.id, onMachine: "local", at: now.advanced(by: .seconds(-120)))
        notifications.recordTyping(tabID: labTab.id, onMachine: ssh.machineID, at: now)
        #expect(policy.decide(notifications.attentionArrival(here)).desktop,
                "remote typing suppressed the same-id local tab after its quiet period expired")
        #expect(!policy.decide(notifications.attentionArrival(lab)).desktop)
    }

    @Test func launchReconciliationWithdrawsOldRequestsButKeepsConcurrentNewBanners() {
        let old = AttentionBannerLifecycle.attentionBannerID(Self.item("old", at: 1_000))
        let fresh = AttentionBannerLifecycle.attentionBannerID(Self.item("fresh", at: 2_000))
        #expect(AttentionBannerLifecycle.staleBannerIDs([old], currentLaunch: []) == [old])
        #expect(AttentionBannerLifecycle.staleBannerIDs([old, fresh, "other-banner"], currentLaunch: [fresh]) == [old])
    }

    @Test func attentionUsesNeedsInputSoundVolumeAndSharedCooldown() {
        _ = NSApplication.shared
        let service = NotificationCenterService()
        let now = ContinuousClock.now
        service.soundGate = NotificationSoundGate(now: { now })
        service.preferences.desktop = .always
        service.preferences.sounds.events = [.needsInput: "Ping", .finished: "Hero"]
        service.preferences.sounds.volume = 0.25
        let first = service.attentionDecision(Self.item("request-one", at: 1_000))
        #expect(first.soundEvent == .needsInput)
        #expect(first.sound == "Ping")
        #expect(first.soundVolume == 0.25)
        let burst = service.attentionDecision(Self.item("request-two", at: 2_000))
        #expect(burst.desktop, "sound cooldown must not suppress the new banner")
        #expect(burst.sound == nil, "a second attention request bypassed the shared cooldown")
    }

    @Test func theBannerOffersShow() {
        let category = DesktopNotifier.attentionBannerCategory()
        #expect(category.identifier == DesktopNotifier.attentionCategory)
        #expect(category.actions.map(\.identifier) == [DesktopNotifier.showAction])
        #expect(category.actions.first?.options.contains(.foreground) == true)
    }
}
