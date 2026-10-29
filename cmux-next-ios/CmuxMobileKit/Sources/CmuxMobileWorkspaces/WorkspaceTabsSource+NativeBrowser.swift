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
    /// hidden). The Mac's own addresses (`localhost`, a `file:` page) stay mirrored.
    public func openOnPhone(_ id: TabsKitTab.ID) {
        guard let tab = workspaceTab(id), tab.kind == .browser, let mirror = mirrored(tab) else { return }
        let url = mirror.url ?? tab.url
        if PhoneReach(url) == .macOnly, let url {
            show("\(Self.addressLabel(url)) is on \(macName). It can only be mirrored.")
            CmuxMobileTheme.standard.haptics.error()
            return
        }
        native.open(tab: tab.id, macID: workspace?.macID, at: url)
        show("Opened on this iPhone. Sign-ins on \(macName) don't carry over.")
    }

    /// Mirror from the Mac again. When the person browsed on the iPhone, the Mac's
    /// tab goes to that page, so the mirror continues where they were.
    public func mirrorFromMac(_ id: TabsKitTab.ID) {
        guard let tab = workspaceTab(id), tab.kind == .browser else { return }
        let carried = native.close(tab: tab.id, macID: workspace?.macID)
        guard let mirror = streamed.model(tab: tab.id, url: tab.url, macID: workspace?.macID) else { return }
        if let carried { mirror.navigate(to: carried.absoluteString) }
    }

    /// Whether the tab can switch between the Mac's page and this iPhone's (linked to its Mac).
    func canOpenOnPhone(_ tab: WorkspaceTab) -> Bool {
        tab.kind == .browser && streamed.model(tab: tab.id, url: tab.url, macID: workspace?.macID) != nil
    }

    /// `localhost:3000`, `example.com`, or a file's name.
    static func addressLabel(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
#endif
