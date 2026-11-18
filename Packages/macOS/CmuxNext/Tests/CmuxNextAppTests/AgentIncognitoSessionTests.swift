import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDaemon
import Foundation
import Testing
import WebKit

/// An agent session's opt-in incognito (decision D1 keeps the person's login as the agents' default): a session that
/// asks for it gets its own `OffTheRecordProfiles` profile and an incognito workspace of its own, made in the
/// background. Its tabs never share the person's profile or the person's shared incognito profile, never move in or
/// out of that workspace, and the session's end closes the workspace and drops the profile (Chromium releases its
/// in-memory contexts, WebKit its non-persistent store). The person's incognito windows keep their one shared profile.
@MainActor @Suite(.serialized)
struct AgentIncognitoSessionTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        return services
    }

    /// The cookies `store` holds for `host`.
    static func cookies(_ store: WKWebsiteDataStore, host: String) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix(host) }
    }

    /// Tests 1 and 2: the session's pages use their own in-memory profile, and a cookie its store gets reaches neither
    /// the person's profile store (nor its directory) nor the person's shared incognito profile.
    @Test func theSessionsStoreIsNeitherThePersonsProfileNorTheirIncognitoOne() async throws {
        let services = Self.services()
        let windows = services.windows
        let profile = windows.agentIncognito.begin("s1").profile
        windows.agentIncognito.attach(workspace: "ws-agent", to: "s1")
        let shared = windows.incognitoProfile()

        #expect(windows.browserProfile(forWorkspace: "ws-agent") == profile)
        #expect(profile != .default)
        #expect(profile != shared, "the session got the person's shared incognito profile")
        #expect(services.browserStores.offTheRecord.contains(profile))

        // Chromium: an in-memory request context, never a directory of the person's profile.
        let storage = CEFProfileStorage(root: FileManager.default.temporaryDirectory.appending(path: "agent-incognito-\(UUID().uuidString)"))
        let context = storage.contextKey(for: profile, machineKey: nil, offTheRecord: services.browserStores.offTheRecord.isOffTheRecord(profile))
        #expect(context.hasPrefix(CEFProfileStorage.offTheRecordPrefix), "the session's Chromium context is on disk: \(context)")
        #expect(context != storage.cachePath(for: .default).path)
        #expect(!storage.isPersistentProfilePath(context))

        // WebKit: a non-persistent store of its own; a cookie it gets stays there.
        let profiles = services.cache.webKit.profileStore
        let store = profiles.dataStore(for: profile)
        #expect(!store.isPersistent)
        #expect(store !== profiles.dataStore(for: .default))
        #expect(store !== profiles.dataStore(for: shared))
        let host = "agent-\(UUID().uuidString.prefix(8).lowercased()).example"
        let cookie = try #require(HTTPCookie(properties: [.domain: host, .path: "/", .name: "agent", .value: "1"]))
        await store.httpCookieStore.setCookie(cookie)
        #expect(await Self.cookies(store, host: host).count == 1)
        #expect(await Self.cookies(profiles.dataStore(for: .default), host: host).isEmpty, "the cookie reached the person's profile")
        #expect(await Self.cookies(profiles.dataStore(for: shared), host: host).isEmpty, "the cookie reached the person's incognito profile")
    }

    /// Two sessions get two profiles.
    @Test func twoSessionsGetTwoProfiles() {
        let services = Self.services()
        let sessions = services.windows.agentIncognito
        let first = sessions.begin("s1").profile, second = sessions.begin("s2").profile
        #expect(first != second)
        #expect(sessions.begin("s1").profile == first, "a session's second tab got a new profile")
    }

    /// Test 3: the session's end closes its workspace and ends its profile: every engine's end observer runs (Chromium
    /// releases its contexts there, `CEFRuntime.adopt(stores:)`), and WebKit drops the store.
    @Test func theSessionsEndClosesItsWorkspaceAndDropsItsProfile() async {
        let services = Self.services()
        let sessions = services.windows.agentIncognito
        var closed: [String] = []
        sessions.closeWorkspace = { closed.append($0) }
        var ended: [BrowserProfileID] = []
        services.browserStores.offTheRecord.observeEnd { ended.append($0) }
        let profile = sessions.begin("s1").profile
        sessions.attach(workspace: "ws-agent", to: "s1")
        let profiles = services.cache.webKit.profileStore
        let store = profiles.dataStore(for: profile)
        let shared = services.windows.incognitoProfile()

        await sessions.end("s1")

        #expect(closed == ["ws-agent"])
        #expect(ended == [profile])
        #expect(!services.browserStores.offTheRecord.contains(profile))
        #expect(profiles.dataStore(for: profile) !== store, "WebKit kept the session's store")
        #expect(sessions.session(ofWorkspace: "ws-agent") == nil)
        // A late page of the closing workspace still never gets a persistent store.
        #expect(services.browserStores.offTheRecord.isOffTheRecord(services.windows.browserProfile(forWorkspace: "ws-agent") ?? .default))
        // The person's shared incognito profile is untouched.
        #expect(services.browserStores.offTheRecord.contains(shared))
        #expect(services.windows.incognitoSession == shared)
        // Once only.
        await sessions.end("s1")
        #expect(closed == ["ws-agent"])
    }

    /// Test 4: the default is unchanged: with a session open, a workspace that is not the session's keeps the
    /// person's profile.
    @Test func aTabThatDidNotAskForIncognitoKeepsThePersonsProfile() {
        let services = Self.services()
        _ = services.windows.agentIncognito.begin("s1")
        services.windows.agentIncognito.attach(workspace: "ws-agent", to: "s1")
        #expect(services.windows.browserProfile(forWorkspace: "ws-normal") == nil)
        #expect(services.windows.agentIncognito.session(ofWorkspace: "ws-normal") == nil)
        #expect(!services.windows.isIncognito(workspace: "ws-normal"))
    }

    /// Test 5: nothing moves into or out of the session's workspace: not to a normal workspace, not to the person's
    /// incognito ones, not to another window.
    @Test func movesIntoOrOutOfTheSessionsWorkspaceAreRefused() throws {
        let services = Self.services()
        let windows = services.windows
        let agentWindow = windows.agentIncognito.begin("s1").window
        windows.agentIncognito.attach(workspace: "ws-agent", to: "s1")
        let personWindow = windows.newIncognitoWindow()
        let personWorkspace = try #require(windows.claims.pending.first { $0.value == personWindow }?.key)
        #expect(windows.isIncognito(workspace: personWorkspace))

        #expect(windows.crossesIncognito(from: "ws-agent", to: "ws-normal"))
        #expect(windows.crossesIncognito(from: "ws-normal", to: "ws-agent"))
        #expect(windows.crossesIncognito(from: "ws-agent", to: personWorkspace))
        #expect(windows.crossesIncognito(from: personWorkspace, to: "ws-agent"))
        #expect(!windows.crossesIncognito(from: "ws-agent", to: "ws-agent"), "a move inside the session's workspace was refused")
        #expect(windows.crossesIncognito(from: "ws-agent", toWindow: personWindow))
        #expect(windows.crossesIncognito(from: personWorkspace, toWindow: agentWindow))
        #expect(windows.crossesKinds(["ws-agent"], to: personWindow))
        #expect(windows.crossesKinds([personWorkspace], to: agentWindow))
        // The person's own incognito moves are as before.
        #expect(!windows.crossesIncognito(from: personWorkspace, to: personWorkspace))
    }

    /// Tests 3 and 6 on a live daemon: the session's first tab opens in an incognito workspace of its own, in a
    /// window that is never key, and the person's active window, its workspace and focused pane stay; the tab uses
    /// the session's profile and is announced to agents. The session's end closes that workspace.
    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func theFirstTabOpensInTheBackgroundAndTheEndClosesItsWorkspace() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let windows = services.windows
            let active = try #require(windows.active)
            let before = (window: active.state.id, workspace: active.state.workspaceID, pane: active.focusedPane?.pane.id,
                          key: NSApp.keyWindow, count: services.daemon.store.workspaces.count)
            let tabs = AppBrowserHostTabs(services: services)
            tabs.start()

            let tab = try await tabs.openIncognitoSessionTab(.webkit, session: "s1", url: nil)

            let workspace = try #require(windows.agentIncognito.workspace(of: "s1"))
            let agentWindow = try #require(windows.agentIncognito.window(of: "s1"))
            #expect(windows.active?.state.id == before.window, "the active window changed")
            #expect(windows.active?.state.workspaceID == before.workspace, "the active workspace changed")
            #expect(windows.active?.focusedPane?.pane.id == before.pane, "the focused pane changed")
            #expect(NSApp.keyWindow === before.key, "the key window changed")
            #expect(windows.controller(for: agentWindow)?.window?.isKeyWindow != true)
            #expect(windows.registry.value.owner(of: workspace) == agentWindow)
            #expect(windows.isIncognito(window: agentWindow))
            #expect(services.browserProfiles.engineProfile(forTab: tab.id) == windows.agentIncognito.begin("s1").profile)
            #expect(services.browserProfiles.engineProfile(forTab: tab.id) != windows.incognitoSession)
            #expect(tabs.isDrivable(tab.id), "the session's own tab is not announced to agents")

            let profile = windows.agentIncognito.begin("s1").profile
            await windows.agentIncognito.end("s1")
            try await PinnedPageTests.until({ services.daemon.store.workspace(id: workspace) == nil },
                                            report: { "the session's workspace is still open" })
            #expect(!services.browserStores.offTheRecord.contains(profile))
            #expect(services.daemon.store.workspaces.count == before.count)
        }
    }
}
