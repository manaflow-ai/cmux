import AppKit
import CmuxNextActions
import Testing

/// Typed results: actions a build cannot run are bound with a reason, and a
/// handler that cannot act reports why instead of no-opping.
@MainActor
@Suite struct ActionUnavailableTests {
    @Test func unavailableActionIsBoundDisabledAndReportsItsReason() {
        let registry = ActionRegistry.standard()
        #expect(registry.bindUnavailable("openDiffViewer", reason: "no diff viewer"))
        #expect(registry.isBound("openDiffViewer"))
        #expect(!registry.unboundActionIDs().contains("openDiffViewer"))
        #expect(registry.unavailableReason(for: "openDiffViewer") == "no diff viewer")
        #expect(registry.unavailableActionIDs() == ["openDiffViewer"])
        #expect(!registry.canPerform("openDiffViewer"))
        #expect(registry.run("openDiffViewer") == .unavailable(reason: "no diff viewer"))
    }

    @Test func unknownIDIsNotBoundAsUnavailable() {
        let registry = ActionRegistry.standard()
        #expect(!registry.bindUnavailable("no.such.action", reason: "x"))
        #expect(registry.unavailableReason(for: "no.such.action") == nil)
    }

    @Test func unavailableActionNeverClaimsASharedShortcut() {
        let registry = ActionRegistry.standard()
        var hits: [String] = []
        registry.context = [.browserFocused, .markdownFocused]
        registry.bindUnavailable("markdownZoomIn", reason: "no markdown viewer")
        registry.bind("browserZoomIn") { hits.append("browser") }
        #expect(registry.performShortcut(Shortcut("=", modifiers: [.command])))
        #expect(hits == ["browser"])
    }

    @Test func bindingARealHandlerClearsTheReason() {
        let registry = ActionRegistry.standard()
        registry.bindUnavailable("jumpToUnread", reason: "later")
        var ran = false
        registry.bind("jumpToUnread") { ran = true }
        #expect(registry.unavailableReason(for: "jumpToUnread") == nil)
        #expect(registry.run("jumpToUnread") == .ran)
        #expect(ran)
    }

    @Test func handlerFailureIsReportedOnceAndIgnoredByPerform() {
        let registry = ActionRegistry.standard()
        var fail = true
        registry.bind("jumpToUnread") { if fail { registry.fail("nothing unread") } }
        #expect(registry.run("jumpToUnread") == .failed(reason: "nothing unread"))
        fail = false
        #expect(registry.run("jumpToUnread") == .ran)
        fail = true
        #expect(registry.perform("jumpToUnread"))
        // A failure left behind by `perform` does not leak into the next run.
        fail = false
        #expect(registry.run("jumpToUnread") == .ran)
    }

    @Test func runOfUnboundOrUnavailableContextIsNotRun() {
        let registry = ActionRegistry.standard()
        #expect(registry.run("jumpToUnread") == .notRun)
        registry.bind("browserHardReload") {}
        registry.context = []
        #expect(registry.run("browserHardReload") == .notRun)
    }
}
