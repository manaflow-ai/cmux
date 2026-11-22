import Foundation
import Testing
@testable import CmuxNextBrowser

@Suite struct StateMachineTests {
    let a = URL(string: "https://a.example/")!
    let b = URL(string: "https://b.example/")!
    let nav1 = BrowserNavigationID(rawValue: 1)
    let nav2 = BrowserNavigationID(rawValue: 2)
    let cancelled = BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, message: "cancelled")
    let offline = BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, message: "offline")

    private func changed(_ machine: inout BrowserTabStateMachine, _ event: BrowserNavigationEvent) -> Bool {
        machine.apply(event)
    }

    private func loaded(_ url: URL, id: BrowserNavigationID) -> BrowserTabStateMachine {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(id, url: url))
        machine.apply(.committed(id, url: url))
        machine.apply(.titleChanged("A"))
        machine.apply(.finished(id))
        return machine
    }

    /// A same-document URL change (pushState, a fragment) keeps what the
    /// engine found about the page: a mixed-content, broken-certificate or
    /// dangerous page never turns "secure" because its path changed.
    @Test func sameDocumentURLChangesKeepEngineSecurity() {
        for refined in [BrowserSecurityState.mixedContent, .broken, .dangerous] {
            var machine = loaded(a, id: nav1)
            machine.apply(.securityChanged(refined))
            machine.apply(.urlChanged(URL(string: "https://a.example/next?x=1#top")!))
            #expect(machine.state.security == refined, "\(refined)")
        }
    }

    @Test func fullNavigationLifecycle() {
        var machine = BrowserTabStateMachine()
        #expect(machine.state.phase == .idle)

        machine.apply(.started(nav1, url: a))
        #expect(machine.state.phase == .provisional)
        #expect(machine.state.isLoading)
        #expect(machine.state.progress == BrowserTabStateMachine.initialProgress)

        machine.apply(.committed(nav1, url: a))
        #expect(machine.state.phase == .committed)
        #expect(machine.state.security == .secure)

        machine.apply(.progress(0.6))
        machine.apply(.titleChanged("  A page \n"))
        #expect(machine.state.title == "A page")

        machine.apply(.finished(nav1))
        #expect(machine.state.phase == .finished)
        #expect(!machine.state.isLoading)
        #expect(machine.state.progress == 1)
        #expect(machine.state.activeNavigation == nil)
    }

    @Test func lateCallbacksFromSupersededNavigationAreIgnored() {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(nav1, url: a))
        machine.apply(.started(nav2, url: b))

        #expect(!changed(&machine, .failed(nav1, offline)))
        #expect(!changed(&machine, .committed(nav1, url: a)))
        #expect(!changed(&machine, .finished(nav1)))
        #expect(machine.state.phase == .provisional)
        #expect(machine.state.url == b)

        machine.apply(.committed(nav2, url: b))
        machine.apply(.finished(nav2))
        #expect(machine.state.phase == .finished)
        #expect(machine.state.url == b)
    }

    @Test func progressIsMonotonicClampedAndIgnoredWhenIdle() {
        var machine = BrowserTabStateMachine()
        #expect(!changed(&machine, .progress(0.5)))
        machine.apply(.started(nav1, url: a))
        machine.apply(.progress(0.7))
        machine.apply(.progress(0.3))
        #expect(machine.state.progress == 0.7)
        machine.apply(.progress(4))
        #expect(machine.state.progress == 1)
        machine.apply(.finished(nav1))
        #expect(!changed(&machine, .progress(0.2)))
    }

    @Test func stoppingBeforeCommitRevertsToThePreviousPage() {
        var machine = loaded(a, id: nav1)
        machine.apply(.started(nav2, url: b))
        #expect(machine.state.url == b)
        machine.apply(.stopped)
        #expect(machine.state.url == a)
        #expect(machine.state.phase == .finished)
        #expect(machine.state.progress == 0)
        #expect(!machine.state.isLoading)
    }

    @Test func stoppingTheFirstLoadReturnsToIdle() {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(nav1, url: a))
        machine.apply(.stopped)
        #expect(machine.state.phase == .idle)
        #expect(machine.state.url == nil)
    }

    @Test func cancellationIsNotAnError() {
        var machine = loaded(a, id: nav1)
        machine.apply(.started(nav2, url: b))
        machine.apply(.failed(nav2, cancelled))
        #expect(machine.state.loadError == nil)
        #expect(machine.state.url == a)

        let download = BrowserLoadError(domain: "WebKitErrorDomain", code: 102, message: "interrupted")
        #expect(download.isBenignInterruption)
    }

    @Test func realFailuresSurface() {
        var machine = loaded(a, id: nav1)
        machine.apply(.started(nav2, url: b))
        machine.apply(.failed(nav2, offline))
        #expect(machine.state.loadError == offline)
        #expect(!machine.state.isLoading)
        #expect(machine.state.activeNavigation == nil)
        // A new navigation clears the error.
        machine.apply(.started(BrowserNavigationID(rawValue: 3), url: a))
        #expect(machine.state.loadError == nil)
    }

    @Test func commitToAnotherHostClearsFaviconAndTitle() {
        var machine = loaded(a, id: nav1)
        machine.apply(.faviconChanged(URL(string: "https://a.example/favicon.ico")))
        machine.apply(.started(nav2, url: a.appending(path: "next")))
        machine.apply(.committed(nav2, url: a.appending(path: "next")))
        #expect(machine.state.faviconURL != nil)
        #expect(machine.state.title == nil)

        let nav3 = BrowserNavigationID(rawValue: 3)
        machine.apply(.started(nav3, url: b))
        machine.apply(.committed(nav3, url: b))
        #expect(machine.state.faviconURL == nil)
    }

    @Test func securityFollowsScheme() {
        #expect(BrowserTabStateMachine.security(for: URL(string: "https://x.example")) == .secure)
        #expect(BrowserTabStateMachine.security(for: URL(string: "http://x.example")) == .insecure)
        #expect(BrowserTabStateMachine.security(for: URL(filePath: "/tmp/x")) == .local)
        #expect(BrowserTabStateMachine.security(for: nil) == .none)
    }

    @Test func sameDocumentURLChangesUpdateTheAddress() {
        var machine = loaded(a, id: nav1)
        let fragment = URL(string: "https://a.example/#section")!
        machine.apply(.urlChanged(fragment))
        #expect(machine.state.url == fragment)
        // A later cancelled navigation reverts to the pushState URL.
        machine.apply(.started(nav2, url: b))
        machine.apply(.stopped)
        #expect(machine.state.url == fragment)
    }

    @Test func zoomIsClampedAndStepsAlongTheLadder() {
        var machine = BrowserTabStateMachine()
        machine.apply(.zoomChanged(12))
        #expect(machine.state.zoom == BrowserZoom.maximum)
        #expect(BrowserZoom.zoomIn(from: 1) == 1.1)
        #expect(BrowserZoom.zoomOut(from: 1) == 0.9)
        #expect(BrowserZoom.zoomIn(from: 1.05) == 1.1)
        #expect(BrowserZoom.zoomOut(from: 1.05) == 1.0)
        #expect(BrowserZoom.zoomIn(from: 5) == 5)
        #expect(BrowserZoom.zoomOut(from: 0.25) == 0.25)
        #expect(BrowserZoom.percent(0.67) == 67)
    }
}
