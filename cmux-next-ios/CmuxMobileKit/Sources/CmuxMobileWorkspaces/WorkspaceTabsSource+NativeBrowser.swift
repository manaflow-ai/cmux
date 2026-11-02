#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileDesign
import CmuxMobileModel
import CmuxTabsKit
import Foundation

/// Open on iPhone / Mirror from <Mac>: a linked browser tab shows the Mac's page
/// (mirrored) or loads it in this iPhone's own web view (`NativeBrowserTabs`).
extension WorkspaceTabsSource {
    /// The tab's page on this iPhone, when the person opened it here instead of the mirror.
    func nativeBrowser(_ tab: WorkspaceTab) -> BrowserTabModel? {
        native.model(tab: tab.id, macID: store.workspace(id: workspaceID)?.macID)
    }

    /// The Mac's page of a mirrored tab (nil: not linked, or the tab is on the iPhone).
    private func mirrored(_ tab: WorkspaceTab) -> StreamedBrowserModel? {
        guard nativeBrowser(tab) == nil else { return nil }
        return streamed.model(tab: tab.id, url: tab.url, macID: store.workspace(id: workspaceID)?.macID)
    }

    /// Open on iPhone: the tab's page loads in this iPhone's own web view at the
    /// Mac's current address. The Mac's tab stays as it is (its stream pauses while
    /// hidden). A Mac `localhost:<port>` page opens here too when the Mac forwards
    /// `localhost` (`LocalhostForwarder`); a `file:` page and the like stay mirrored.
    public func openOnPhone(_ id: TabsKitTab.ID) {
        guard let tab = workspaceTab(id), tab.kind == .browser, let mirror = mirrored(tab) else { return }
        let url = mirror.url ?? tab.url
        let reach = PhoneReach(url)
        if let url, reach == .macOnly || (reach == .macLoopback && !native.canForward(macID: workspace?.macID)) {
            show("\(Self.addressLabel(url)) is on \(macName). It can only be mirrored.")
            CmuxMobileTheme.standard.haptics.error()
            return
        }
        native.open(tab: tab.id, macID: workspace?.macID, at: url)
        // The person's tap shows in this turn: the tab's toolbar reads the phone's page now.
        refreshTab(tab.id)
        show("Opened on this iPhone. Sign-ins on \(macName) don't carry over.")
    }

    /// Mirror from the Mac again. When the person browsed on the iPhone, the Mac's
    /// tab goes to that page, so the mirror continues where they were.
    /// Not linked, the tab stays on the phone (nothing to mirror; its page is the newest there is).
    public func mirrorFromMac(_ id: TabsKitTab.ID) {
        guard let tab = workspaceTab(id), tab.kind == .browser, canMirror(tab),
              let mirror = streamed.model(tab: tab.id, url: tab.url, macID: workspace?.macID) else { return }
        // Already there (the person came back to where the Mac is): no reload of the Mac's page.
        if let carried = native.close(tab: tab.id, macID: workspace?.macID), carried != mirror.url {
            mirror.navigate(to: carried.absoluteString)
        }
        refreshTab(tab.id)
    }

    /// Whether the tab can switch between the Mac's page and this iPhone's (linked to its Mac).
    func canOpenOnPhone(_ tab: WorkspaceTab) -> Bool { canMirror(tab) }

    /// Linked to the tab's Mac: its page can be mirrored.
    func canMirror(_ tab: WorkspaceTab) -> Bool {
        tab.kind == .browser && streamed.isLive
    }

    /// `localhost:3000`, `example.com`, or a file's name.
    static func addressLabel(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
#endif
