import AppKit
@testable import CmuxNextBrowser
import Testing

/// #24913: a Chromium focus grant makes the page window key, the key change runs the focus model,
/// which asks the same page for focus again. A grant asked for inside a grant, or for a page whose
/// window is already key, reaches CEF no more: one key change per focus request.
@Suite struct CEFFocusGrantTests {
    @Test func aGrantFromInsideAGrantIsDropped() {
        var grant = CEFFocusGrant()
        var calls = 0
        func ask() {
            _ = grant.grant(pageWindowIsKey: false) {
                calls += 1
                // CEF's makeKeyAndOrderFront -> didBecomeKey -> the focus model asks again.
                if calls < 20 { ask() }
            }
        }
        ask()
        #expect(calls == 1, "nested grants reached CEF \(calls) times")
        #expect(grant.grants == 1)
        #expect(!grant.isGranting)
    }

    @Test func aPageWhoseWindowIsKeyAlreadyAsksNothing() {
        var grant = CEFFocusGrant()
        var calls = 0
        #expect(!grant.grant(pageWindowIsKey: true) { calls += 1 })
        #expect(grant.grant(pageWindowIsKey: false) { calls += 1 })
        #expect(calls == 1)
    }
}
