import CmuxNextBrowser
import CmuxNextFeatures

// Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md section 6).
extension AppServices {
    /// Follows the runtime download, and makes every "can Chromium open a
    /// tab?" check that finds the download pending ask for it at user
    /// priority (a tab, the palette or the CLI wanted Chromium now).
    func startChromiumRuntime() {
        let runtime = chromiumRuntime
        runtime.start(on: mainDeadlines)
        let browserTabs = cache.browserTabs
        let engineReason = browserTabs.cefUnavailable
        browserTabs.cefUnavailable = { [weak runtime] in
            let reason = engineReason()
            if reason?.isAwaitingDownload == true { runtime?.wanted() }
            return reason
        }
    }

    /// ``chromiumRuntime`` at its first read (p08-startup-098): built from the launch's files-lane pick
    /// (``chromiumRuntimePick``), or picked here when a reader comes before that read ends. The host-mode
    /// switches are set before any reader gets the runtime's source.
    func makeChromiumRuntime() -> ChromiumRuntimeService {
        let runtime = ChromiumRuntimeService.make(chromiumRuntimePick.value ?? ChromiumRuntimeService.pick(), work: work)
        let source = runtime.source
        // Host mode only: the host's widgets in cmux panels and panes (p01-process-066).
        source.showsHostWidgets = features.isEnabled(.chromiumHostWidgets)
        // Host mode only: drags onto a page as Chrome's own drop (p01-process-050).
        source.takesHostDrags = features.isEnabled(.chromiumHostDragIn)
        source.fencesHostResizes = features.isEnabled(.chromiumHostResizeFence) // p01-process-052
        // Host mode only: <select> popups as cmux menus (p01-process-060).
        source.drawsHostPopupMenus = features.isEnabled(.chromiumHostPopupMenus)
        source.drawsHostSuggestions = features.isEnabled(.chromiumHostSuggestions) // p01-process-061
        // Host mode only: page file choosers in cmux's picker, the files sent as paths (p01-process-064).
        source.hostFileDialogs = features.isEnabled(.chromiumHostFileDialogs) ? ChromiumFileDialogPanels(openPanel: openPanel) : nil
        return runtime
    }
}
