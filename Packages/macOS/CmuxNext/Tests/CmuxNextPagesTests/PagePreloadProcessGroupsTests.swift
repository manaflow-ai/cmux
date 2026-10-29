import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
import WebKit

/// With `webKitPageProcessGroups` a page the preload slot loads parked in WebKit joins its capability
/// group as a cold open of it does (p07-memory-087 on p13-webui-045): the slot makes the page it will
/// show, never a spare that a claim retargets, so a parked History is related to the open Cloud page in
/// the groups' store, and a parked Settings (`solo`) stays in a process and a store of its own.
/// PageHostPoolProcessGroupsTests checked the same rule on the retired pool's spare.
@MainActor @Suite(.serialized) struct PagePreloadProcessGroupsTests {
    static let key = PagePreloadSlot.Key("page.history")

    func makeHost(_ groups: WebProcessGroups) -> WebUIHost {
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never,
                             processGroups: groups)
        host.preload = PagePreloadSlot(parkState: .frozenHidden, deadlines: LifecycleDeadlineRig.never)
        return host
    }

    private static func bootsParked(_ view: PageWebView) -> Bool {
        view.userContent.userScripts.contains { $0.source == PageWebView.parkedScript }
    }

    @Test func aParkedHistoryJoinsTheOpenPrivilegedPage() throws {
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let groups = WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: true)
        let host = makeHost(groups)
        let slot = try #require(host.preload)
        let cloud = try #require(host.open(PageOpenRequest(descriptor: .cloud, routes: [])))
        defer { host.close(cloud) }

        var made: PageWebView?
        #expect(slot.preload(Self.key, size: NSSize(width: 800, height: 600), in: parking) { _ in
            made = host.open(PageOpenRequest(descriptor: .history, routes: [], parked: true))
            return made
        })
        let history = try #require(made)
        defer { host.close(history) }
        #expect(history.isPooled && Self.bootsParked(history))
        #expect(history.webView.configuration.value(forKey: "_relatedWebView") as? WKWebView === cloud.webView)
        #expect(history.webView.configuration.websiteDataStore === groups.dataStore(for: .group(.privileged)))
        #expect(history.crash.sharesWebKitProcess)
    }

    /// Settings is `solo`: parked or cold, it joins no group.
    @Test func aParkedSettingsJoinsNoGroup() throws {
        let groups = WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: true)
        let host = makeHost(groups)
        let settings = try #require(host.open(PageOpenRequest(descriptor: .settings, routes: [], parked: true)))
        defer { host.close(settings) }
        #expect(settings.isPooled && Self.bootsParked(settings))
        #expect(settings.webView.configuration.websiteDataStore !== groups.dataStore(for: .page(PageDescriptor.settings.id)),
                "a parked Settings joined a group")
        #expect(settings.webView.configuration.value(forKey: "_relatedWebView") == nil)
        #expect(!settings.crash.sharesWebKitProcess)
    }

    /// Off, only the pages that ask (`sharesWebKitProcess`) share: a parked History is in no group.
    @Test func offAParkedHistoryJoinsNoGroup() throws {
        let groups = WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: false)
        let host = makeHost(groups)
        let history = try #require(host.open(PageOpenRequest(descriptor: .history, routes: [], parked: true)))
        defer { host.close(history) }
        #expect(history.webView.configuration.websiteDataStore !== groups.dataStore(for: .group(.privileged)))
        #expect(!history.crash.sharesWebKitProcess)
    }
}
