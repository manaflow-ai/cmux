@testable import CmuxNextBrowser

/// Red proof only (never lands): the base has no spare window for the cmux pages' store.
extension CEFRuntime {
    var pageSpareWindow: CEFSpareWindow? { nil }
    func usePageSpareWindow(profile: BrowserProfileID) {}
}
