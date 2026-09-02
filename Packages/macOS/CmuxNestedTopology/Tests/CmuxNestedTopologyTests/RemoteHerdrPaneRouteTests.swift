import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrPaneRouteTests {
    @Test func unknownPaneOutputIsNoop() {
        var router = RemoteHerdrPaneRoute()
        #expect(router.routeOutput(paneID: "w2:p1", data: Data("hello".utf8)) == nil)
        #expect(router.buffers.isEmpty)
    }

    @Test func neverWritesAcrossPanes() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        router.bind(paneID: "w2:p2", surfaceID: "s2")
        let write = router.routeOutput(paneID: "w2:p1", data: Data("alpha".utf8))
        #expect(write?.surfaceID == "s1")
        #expect(router.buffer(for: "w2:p1") == Data("alpha".utf8))
        #expect(router.buffer(for: "w2:p2").isEmpty)
    }

    @Test func titleBytesNeverReachSurface() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        _ = router.routeOutput(paneID: "w2:p1", data: Data("hi\u{1b}ktitle\u{1b}\\there".utf8))
        #expect(router.buffer(for: "w2:p1") == Data("hithere".utf8))
    }

    @Test func titleFilterSplitsAcrossChunks() {
        var filter = RemoteHerdrTitleEscapeFilter()
        #expect(filter.filter(Data("ab\u{1b}kti".utf8)) == Data("ab".utf8))
        #expect(filter.filter(Data("tle\u{1b}\\cd".utf8)) == Data("cd".utf8))
    }

    @Test func textDeltaIncrementalThenRedraw() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        let first = router.routeOutputText(paneID: "w2:p1", current: "hello")
        #expect(first?.fullRedraw == true)
        let second = router.routeOutputText(paneID: "w2:p1", current: "hello\nworld")
        #expect(second?.fullRedraw == false)
        #expect(second?.data == Data("\nworld".utf8))
        let third = router.routeOutputText(paneID: "w2:p1", current: "goodbye")
        #expect(third?.fullRedraw == true)
        #expect(router.buffer(for: "w2:p1") == Data("goodbye".utf8))
    }

    @Test func unknownPaneInputIsNoop() {
        var router = RemoteHerdrPaneRoute()
        #expect(router.routeInput(paneID: "w2:p1", data: Data("x".utf8)) == nil)
    }

    @Test func onlyBoundPaneReceivesKeys() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        router.bind(paneID: "w2:p2", surfaceID: "s2")
        let send = router.routeInput(paneID: "w2:p2", data: Data("xy".utf8))
        #expect(send?.paneID == "w2:p2")
        #expect(!router.log.contains(where: { $0.hasPrefix("in:w2:p1") }))
    }

    @Test func providerNeverSends() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        let result = router.projectFocus(paneID: "w2:p1", fromProvider: true)
        #expect(result.sendToProvider == false)
        #expect(result.source == "provider")
        #expect(router.activePaneID == "w2:p1")
    }

    @Test func userSendsOnceUntilEcho() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        router.setLivePanes(["w2:p1", "w2:p2"])
        let first = router.projectFocus(paneID: "w2:p2", fromProvider: false)
        #expect(first.sendToProvider == true)
        let second = router.projectFocus(paneID: "w2:p2", fromProvider: false)
        #expect(second.sendToProvider == false)
        let echo = router.projectFocus(paneID: "w2:p2", fromProvider: true)
        #expect(echo.sendToProvider == false)
        #expect(router.pendingUserFocus == nil)
        let third = router.projectFocus(paneID: "w2:p2", fromProvider: false)
        #expect(third.sendToProvider == true)
    }

    @Test func userUnknownPaneIsNoop() {
        var router = RemoteHerdrPaneRoute()
        let result = router.projectFocus(paneID: "w2:missing", fromProvider: false)
        #expect(result.paneID == nil)
        #expect(result.sendToProvider == false)
    }

    @Test func providerUnknownPaneStillProjects() {
        var router = RemoteHerdrPaneRoute()
        let result = router.projectFocus(paneID: "w2:pending", fromProvider: true)
        #expect(result.paneID == "w2:pending")
        #expect(result.sendToProvider == false)
        #expect(router.activePaneID == "w2:pending")
    }

    @Test func backgroundCdDoesNotHijackTab() {
        var router = RemoteHerdrPaneRoute()
        router.bind(paneID: "w2:p1", surfaceID: "s1")
        router.bind(paneID: "w2:p2", surfaceID: "s2")
        _ = router.noteRemoteActive(paneID: "w2:p1")
        let background = router.routeCwd(paneID: "w2:p2", path: "/tmp/other", tabID: "w2:t1")
        #expect(background?.applyToTab == false)
        let active = router.routeCwd(paneID: "w2:p1", path: "/tmp/here", tabID: "w2:t1")
        #expect(active?.applyToTab == true)
    }
}
