import Foundation
import Testing
@testable import CmuxBrowser

/// Coverage for the `browser.autoRestoreUnloadedPages` setting
/// (https://github.com/manaflow-ai/cmux/issues/9561 and
/// https://github.com/manaflow-ai/cmux/issues/15069): with it off, a page
/// unloaded to save memory waits for the user instead of restoring when its
/// pane is shown.
@MainActor
struct BrowserHiddenWebViewManualRestoreTests {
    @Test("Unloaded pages restore automatically unless the setting is off")
    func policyDefaultsToAutomaticRestore() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        #expect(BrowserHiddenWebViewDiscardPolicy.autoRestoresUnloadedPages(defaults: defaults))
        #expect(BrowserHiddenWebViewDiscardPolicy.resolved(defaults: defaults).autoRestoresUnloadedPages)

        defaults.set(false, forKey: BrowserHiddenWebViewDiscardPolicy.autoRestoreKey)
        #expect(!BrowserHiddenWebViewDiscardPolicy.autoRestoresUnloadedPages(defaults: defaults))
        #expect(!BrowserHiddenWebViewDiscardPolicy.resolved(defaults: defaults).autoRestoresUnloadedPages)
    }

    @Test("A page unloaded for memory waits for the user only when automatic restore is off")
    func discardedPageWaitsWhenAutomaticRestoreIsOff() {
        let (automaticDefaults, automaticCleanup) = makeDefaults()
        defer { automaticCleanup() }
        let automatic = BrowserHiddenWebViewDiscardManager(policyDefaults: automaticDefaults)
        automatic.markDiscarded(reason: BrowserHiddenWebViewDiscardManager.memoryBudgetReason, now: Date())
        #expect(!automatic.waitsForManualRestore)

        let (manual, manualCleanup) = makeManualManager()
        defer { manualCleanup() }
        #expect(!manual.waitsForManualRestore)
        manual.markDiscarded(reason: BrowserHiddenWebViewDiscardManager.memoryBudgetReason, now: Date())
        #expect(manual.waitsForManualRestore)
    }

    @Test("A restore the user started no longer waits")
    func startedRestoreStopsWaiting() {
        let (manager, cleanup) = makeManualManager()
        defer { cleanup() }
        manager.markDiscarded(reason: BrowserHiddenWebViewDiscardManager.systemMemoryPressureReason, now: Date())
        #expect(manager.waitsForManualRestore)

        manager.noteRestoreNavigationStarted(reason: "manual_restore")
        #expect(!manager.waitsForManualRestore)

        #expect(manager.noteRestoreNavigationCommitted(reason: "manual_restore"))
        #expect(!manager.waitsForManualRestore)
    }

    @Test("A relaunched pane's deferred first load never waits for the user")
    func deferredFirstLoadDoesNotWait() {
        let (manager, cleanup) = makeManualManager()
        defer { cleanup() }
        manager.markDiscarded(reason: "session_restore", now: Date(), isDeferredFirstLoad: true)
        #expect(manager.isDeferredFirstLoad)
        #expect(!manager.waitsForManualRestore)

        manager.resetMetadata()
        #expect(!manager.isDeferredFirstLoad)
        manager.markDiscarded(reason: BrowserHiddenWebViewDiscardManager.memoryBudgetReason, now: Date())
        #expect(manager.waitsForManualRestore)
    }

    @Test("Clearing the discard also clears the deferred first load")
    func clearingDiscardResetsDeferredFirstLoad() {
        let (manager, cleanup) = makeManualManager()
        defer { cleanup() }
        manager.markDiscarded(reason: "session_restore", now: Date(), isDeferredFirstLoad: true)
        #expect(manager.clearDiscardState(reason: "test"))
        #expect(!manager.isDeferredFirstLoad)
        #expect(!manager.waitsForManualRestore)
    }

    private func makeManualManager() -> (BrowserHiddenWebViewDiscardManager, () -> Void) {
        let (defaults, cleanup) = makeDefaults()
        defaults.set(false, forKey: BrowserHiddenWebViewDiscardPolicy.autoRestoreKey)
        return (BrowserHiddenWebViewDiscardManager(policyDefaults: defaults), cleanup)
    }

    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "cmux-hidden-webview-manual-restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
