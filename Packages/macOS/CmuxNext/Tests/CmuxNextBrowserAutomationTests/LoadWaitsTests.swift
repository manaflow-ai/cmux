import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// A load wait belongs to the navigation its call started. The macOS 26
/// cases come from a WKWebView probe on macOS 26.5: a refused load commits
/// and finishes about:blank instead of failing, and a fragment load gets no
/// delegate callbacks and shows `#` as `%23` in the web view's URL.
@MainActor
@Suite struct LoadWaitsTests {
    static let refused = BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, message: "refused")
    static let cancelled = BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, message: "cancelled")

    func nav(_ raw: UInt64) -> BrowserNavigationID { BrowserNavigationID(rawValue: raw) }

    /// Starts a wait and returns once it is pending.
    func wait(_ waits: LoadWaits, _ target: LoadState, _ ticket: LoadWaits.Ticket) async -> Task<Void, any Error> {
        let before = waits.pendingCount
        let task = Task { try await waits.reach(target, for: ticket, timeout: nil, what: "page.goto") }
        while waits.pendingCount == before { await Task.yield() }
        return task
    }

    @Test func anotherDocumentsCommitAndLoadDoNotMeetTheWaitAndItsFailureFailsIt() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nav(1) }
        let task = await wait(waits, .load, ticket)
        // The initial about:blank document: no navigation of ours committed it.
        waits.signal(.commit, document: "blank")
        waits.signal(.domcontentloaded, document: "blank")
        waits.signal(.load, document: "blank")
        #expect(waits.pendingCount == 1)
        waits.navigationEvent(.failed(nav(1), Self.refused))
        let error = await #expect(throws: DriverError.self) { try await task.value }
        #expect(error?.code == .invalid)
    }

    @Test func itsOwnCommitAndFinishMeetTheWaitsAndOthersDoNot() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nav(2) }
        let commit = await wait(waits, .commit, ticket)
        let load = await wait(waits, .load, ticket)
        waits.navigationEvent(.committed(nav(1), url: nil))
        waits.navigationEvent(.finished(nav(1)))
        #expect(waits.pendingCount == 2)
        waits.navigationEvent(.committed(nav(2), url: nil))
        try await commit.value
        #expect(waits.pendingCount == 1)
        waits.navigationEvent(.finished(nav(2)))
        try await load.value
    }

    @Test func domContentLoadedComesFromTheDocumentItsNavigationCommitted() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nav(3) }
        let task = await wait(waits, .domcontentloaded, ticket)
        waits.signal(.domcontentloaded, document: "blank")
        waits.navigationEvent(.committed(nav(3), url: nil))
        waits.signal(.commit, document: "page")
        #expect(waits.pendingCount == 1)
        waits.signal(.domcontentloaded, document: "page")
        try await task.value
    }

    @Test(arguments: [false, true])
    func aReplacedNavigationHandsItsWaitToTheReplacement(replacementStartsFirst: Bool) async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nav(4) }
        let task = await wait(waits, .load, ticket)
        waits.navigationEvent(.started(nav(4), url: nil))
        if replacementStartsFirst { waits.navigationEvent(.started(nav(5), url: nil)) }
        waits.navigationEvent(.failed(nav(4), Self.cancelled))
        if !replacementStartsFirst { waits.navigationEvent(.started(nav(5), url: nil)) }
        #expect(waits.pendingCount == 1)
        waits.navigationEvent(.finished(nav(5)))
        try await task.value
    }

    @Test func aRefusedLoadThatCommitsABlankDocumentFails() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation(requestedURL: URL(string: "http://127.0.0.1:9/refused")) { nav(7) }
        let task = await wait(waits, .load, ticket)
        waits.navigationEvent(.started(nav(7), url: URL(string: "http://127.0.0.1:9/refused")))
        waits.navigationEvent(.committed(nav(7), url: URL(string: "about:blank")))
        let error = await #expect(throws: DriverError.self) { try await task.value }
        #expect(error?.code == .invalid)
    }

    @Test func aRequestedAboutBlankMayCommitAboutBlank() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation(requestedURL: URL(string: "about:blank")) { nav(8) }
        let task = await wait(waits, .commit, ticket)
        waits.navigationEvent(.started(nav(8), url: nil))
        waits.navigationEvent(.committed(nav(8), url: URL(string: "about:blank")))
        try await task.value
    }

    @Test func aLoadThatNeverStartedIsMetWhenLoadingEnds() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation(requestedURL: URL(string: "data:text/html,a#x")) { nav(9) }
        let task = await wait(waits, .load, ticket)
        waits.loadingEnded()
        try await task.value
    }

    @Test func aStartedLoadIsNotMetWhenLoadingEnds() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nav(10) }
        let task = await wait(waits, .load, ticket)
        waits.navigationEvent(.started(nav(10), url: nil))
        waits.loadingEnded()
        #expect(waits.pendingCount == 1)
        waits.navigationEvent(.finished(nav(10)))
        try await task.value
    }

    @Test func loadingThatEndedBeforeTheWaitExistsMeetsANeverStartedLoad() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nav(11) }
        waits.loadingEnded()
        try await waits.reach(.load, for: ticket, timeout: nil, what: "page.goto")
    }

    /// WebKit changes the URL of a same-document load inside the `load`
    /// call, before the call's wait exists; the wait is met at once.
    @Test func aSameDocumentNavigationDuringTheStartMeetsTheWait() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation {
            waits.sameDocument()
            return nav(6)
        }
        try await waits.reach(.load, for: ticket, timeout: nil, what: "page.goto")
        #expect(waits.pendingCount == 0)
    }

    @Test func withoutANavigationTheNextCommittedDocumentMeetsTheWait() async throws {
        let waits = LoadWaits()
        let ticket = waits.beginNavigation { nil }
        let task = await wait(waits, .load, ticket)
        waits.signal(.commit, document: "page")
        #expect(waits.pendingCount == 1)
        waits.signal(.load, document: "page")
        try await task.value
    }
}
