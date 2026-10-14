public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
import CmuxNextSettings

// The window's chrome state reaches the page as `data-*` attributes of `<html>`, kept current:
// `data-app-sidebar` is `hidden` while the window's sidebar is hidden, else `shown` (the Settings
// page fades its section list's border then, nxdog41). Set when the page joins a window and when
// the window's sidebar changes (`WindowChromeHosting`), and again on every new document.
extension PageWebView {
    /// Sets `data-<name>` on the page's `<html>` now and on every later document.
    public func setDocumentAttribute(_ name: String, _ value: String) {
        guard liveDocumentAttributes[name] != value else { return }
        liveDocumentAttributes[name] = value
        applyLiveDocumentAttributes()
    }

    /// The window's chrome changed (it joined a window, or the window's sidebar hid or showed).
    public func windowDidChangeChrome() {
        guard let host = window as? WindowChromeHosting else { return }
        setDocumentAttribute("app-sidebar", host.sidebarHidden ? "hidden" : "shown")
    }

    func applyLiveDocumentAttributes() {
        Self.labsViews.add(self) // from its first document on, a Labs change reaches it too
        Self.followLabs()
        guard loaded, let script = Self.attributesScript(liveDocumentAttributes.merging(["labs": Self.labs]) { mine, _ in mine })
        else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

// Labs (hq#1980): the flags that are on reach every page as `data-labs` on `<html>`, the names
// space separated (webviews/src/experiments/labs.ts reads them), at document start and on change.
extension PageWebView {
    static let labsViews = NSHashTable<PageWebView>.weakObjects()
    private static var labsObservation: Task<Void, Never>?

    /// The names of the Labs flags that are on, space separated.
    static var labs: String { LabsState.shared.on.joined(separator: " ") }

    /// From the first page's first document on, a Labs change reaches every page with a document.
    static func followLabs() {
        guard labsObservation == nil else { return }
        // task-owner: app lifetime (pages come and go; the flags do not); event-driven (Observation)
        labsObservation = Task { @MainActor in
            for await _ in ObservationStream({ LabsState.shared.on }) {
                for view in labsViews.allObjects { view.applyLiveDocumentAttributes() }
            }
        }
    }
}
