@testable import CmuxNextBrowser
import Foundation
import Testing

/// `BrowserTabState.documentGeneration` changes with each committed document, a reload of the same
/// address too, and never on a same-document navigation (pushState, a fragment): Chrome's
/// `WebContentsObserver::PrimaryPageChanged`, which Memory Saver's background activity
/// (`PageBackgroundActivity`) keys each document's first title and icon on.
@Suite struct BrowserDocumentGenerationTests {
    let dashboard = URL(string: "https://example.com/dashboard")!

    @Test func eachCommitIsANewDocumentAndASameDocumentChangeIsNot() {
        var machine = BrowserTabStateMachine()
        let first = BrowserNavigationID(rawValue: 1)
        machine.apply(.started(first, url: dashboard))
        #expect(machine.state.documentGeneration == 0, "a provisional load is not a document yet")
        machine.apply(.committed(first, url: dashboard))
        machine.apply(.titleChanged("Dashboard"))
        machine.apply(.finished(first))
        let loaded = machine.state.documentGeneration
        #expect(loaded == 1)

        machine.apply(.urlChanged(URL(string: "https://example.com/dashboard#week")!))
        machine.apply(.urlChanged(URL(string: "https://example.com/dashboard/settings")!))
        machine.apply(.titleChanged("Settings"))
        #expect(machine.state.documentGeneration == loaded, "pushState and fragments keep the document")

        let reload = BrowserNavigationID(rawValue: 2)
        machine.apply(.started(reload, url: dashboard))
        machine.apply(.committed(reload, url: dashboard))
        #expect(machine.state.documentGeneration == loaded + 1, "a same-address reload is a new document")
        #expect(machine.state.title == nil)
    }

    @Test func aSupersededCommitIsNotADocument() {
        var machine = BrowserTabStateMachine()
        let old = BrowserNavigationID(rawValue: 1)
        let new = BrowserNavigationID(rawValue: 2)
        machine.apply(.started(old, url: dashboard))
        machine.apply(.started(new, url: dashboard))
        machine.apply(.committed(old, url: dashboard))
        #expect(machine.state.documentGeneration == 0)
    }
}
