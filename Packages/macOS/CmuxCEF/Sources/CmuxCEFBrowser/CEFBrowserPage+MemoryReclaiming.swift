public import CmuxBrowser
import CmuxCEF

/// Browser Memory Saver for Chromium pages: releasing closes the Chromium
/// browser (its renderer exits once no other page uses it) and keeps the page,
/// its view and its history; `restoreContent()`, a load, a reload or a history
/// step recreates it.
extension CEFBrowserPage: BrowserPageMemoryReclaiming {
    /// The helper process rendering the main frame, or nil while the page
    /// is not live or the provider gave the page no process resolver.
    public var contentProcessIdentifier: Int? {
        guard let resolver = rendererProcesses, let mainFrame = browser.rendererClientIDs().first,
              let pid = resolver.pid(forRendererClientID: mainFrame) else { return nil }
        return Int(pid)
    }

    /// `true` while Chromium's browser is closed to save memory.
    public var isContentReleased: Bool { browser.isContentReleased }

    /// The panel's busy-probe bookkeeping for this page.
    public var reclaimProbe: BrowserPageReclaimProbe {
        get { reclaimProbeState }
        set { reclaimProbeState = newValue }
    }

    /// Closes the Chromium browser, keeping the page and its history.
    /// - Returns: `false` when the page is not live or its history cannot be saved.
    public func releaseContent() -> Bool {
        browser.releaseContent()
    }

    /// Recreates the Chromium browser from the saved history.
    public func restoreContent() {
        browser.restoreContent()
    }
}
