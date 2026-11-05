import Foundation

/// The spare Chromium window and the page made ahead in it (`CEFSpareWindow`), for the warmup that
/// makes them at idle moments (`ChromiumWarmup`) and for `debug.cef`.
extension CEFEngine {
    /// Builds the spare Chromium window once Chromium runs and no Chromium window is being built, so a
    /// pane's first tab skips building one; with it up, makes the spare page in it instead (Debug Settings
    /// `browserPage.sparePage`, off by default), so a new tab skips `tab_add`. Call at an idle moment:
    /// either holds the main thread. True when it started.
    @discardableResult
    public func prepareSpareWindow() -> Bool {
        adoptStores()
        return CEFRuntime.shared.spareWindow.prepare(runtime: .shared)
    }

    /// Closes the untaken spare Chromium window and its waiting page, if up (`debug.cef drop_spare`: what
    /// the spare costs). The next take-free idle moment does not make another; a warm start or a take does.
    public func dropSpareWindow() {
        CEFRuntime.shared.spareWindow.drop(runtime: .shared)
    }

    /// Runs when no spare Chromium window or page is ready (a pane or a new tab took it, or a tab's own
    /// window came up first), so the caller can make one at an idle moment (`prepareSpareWindow`). Nil: none.
    public var onSpareWindowNeeded: (@MainActor () -> Void)? {
        get { CEFRuntime.shared.spareWindow.onNeeded }
        set { CEFRuntime.shared.spareWindow.onNeeded = newValue }
    }

    /// Memory pressure holds the spare page (`CEFSpareWindow.holdPages`): true closes the waiting one
    /// and makes none; false lets the next idle moment make it again.
    public func holdSparePages(_ held: Bool) {
        CEFRuntime.shared.spareWindow.holdPages(held)
    }

    /// `none`, `creating`, `live`, `taken` or `closed` (`debug.cef`).
    public var spareWindowState: String { CEFRuntime.shared.spareWindow.state.rawValue }

    /// `waiting` or `none`: the spare page made ahead (`debug.cef` `spare_page`).
    public var sparePageState: String { CEFRuntime.shared.spareWindow.pageState }

    /// Spare pages a new tab took in this process (`debug.cef` `spare_pages_taken`).
    public var sparePagesTaken: Int { CEFRuntime.shared.spareWindow.pagesTaken }
}
