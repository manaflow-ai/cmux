public import AppKit
import CmuxNextDesign
import Foundation

/// Development hook until the App layer maps daemon browser tabs into panes:
/// a standalone window with one browser pane.
///
///   CMUX_NEXT_DEBUG_BROWSER=cef|webkit      engine
///   CMUX_NEXT_DEBUG_BROWSER_URL=<url>       first page (default example.com)
///   CMUX_NEXT_DEBUG_BROWSER_REPORT=<path>   JSON status file, rewritten on
///                                           every change (verification)
///   CMUX_NEXT_DEBUG_BROWSER_EVAL=<js>       evaluated after each load; the
///                                           result lands in the report
///   CMUX_NEXT_DEBUG_BROWSER_OPEN_EXTENSION=1 runs the first extension action
///                                           (opens its popup) once listed
///   CMUX_NEXT_NO_ACTIVATE=1                 never activate the app
public final class BrowserDebugWindow: NSObject, BrowserTabDelegate {
    private static var open: [BrowserDebugWindow] = []

    private let window: NSWindow
    private let chrome: BrowserChromeView
    private var tabs: [any BrowserTab]
    private let reportURL: URL?
    private var observation: ObservationLoop?
    private let evalScript = ProcessInfo.processInfo.environment["CMUX_NEXT_DEBUG_BROWSER_EVAL"]
    private var evalResult: String?
    private var evaluatedURL: URL?
    private var openExtension = ProcessInfo.processInfo.environment["CMUX_NEXT_DEBUG_BROWSER_OPEN_EXTENSION"] == "1"

    /// Opens the window when `CMUX_NEXT_DEBUG_BROWSER` is set. Returns the
    /// failure text when the engine cannot create a tab.
    @discardableResult
    public static func showIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let engineName = environment["CMUX_NEXT_DEBUG_BROWSER"], !engineName.isEmpty else { return nil }
        let url = environment["CMUX_NEXT_DEBUG_BROWSER_URL"].flatMap(URL.init(string:)) ?? URL(string: "https://example.com")!
        let report = environment["CMUX_NEXT_DEBUG_BROWSER_REPORT"].map { URL(filePath: $0) }
        let configuration = BrowserTabConfiguration(initialURL: url, pane: BrowserPaneID(rawValue: "debug-window"))
        do {
            let tab: any BrowserTab = if engineName == "cef" {
                try CEFEngine().makeCEFTab(configuration)
            } else {
                WebKitEngine().makeWebKitTab(configuration)
            }
            let debugWindow = BrowserDebugWindow(tab: tab, report: report, activate: environment["CMUX_NEXT_NO_ACTIVATE"] != "1")
            open.append(debugWindow)
            return nil
        } catch {
            let message = String(describing: error)
            writeReport(["error": message], to: report)
            return message
        }
    }

    private init(tab: any BrowserTab, report: URL?, activate: Bool) {
        tabs = [tab]
        reportURL = report
        chrome = BrowserChromeView(tab: tab)
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "cmux-next browser (\(tab.engineKind.rawValue))"
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        tab.delegate = self
        if !activate { WindowPlacement.noActivate = true }
        WindowPlacement.present(window)
        observe()
    }

    private func observe() {
        observation?.cancel()
        observation = ObservationLoop { [weak self] in self?.report() }
    }

    public func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        switch intent {
        case .adoptTab(let child, _):
            child.delegate = self
            tabs.append(child)
            chrome.tab = child
            observe()
        case .openURL(let url, _):
            chrome.tab.load(url)
        case .close:
            tabs.removeAll { $0 === tab }
            if let next = tabs.last { chrome.tab = next; observe() } else { window.close() }
        case .download:
            break
        case .activate:
            chrome.tab = tab
            observe()
        case .contextMenu(let request):
            BrowserContextMenuBuilder.present(request, in: tab.contentView)
        case .notice(let text):
            chrome.showNotice(text)
        case .rerouteStore:
            // The debug window has no machines, so it never sets a guard.
            break
        }
    }

    private func report() {
        let tab = chrome.tab
        let state = tab.state
        var fields: [String: Any] = [
            "engine": tab.engineKind.rawValue,
            "url": state.url?.absoluteString ?? "",
            "title": state.title ?? "",
            "loading": state.isLoading,
            "tabs": tabs.count,
            "windowNumber": window.windowNumber,
        ]
        if let error = state.loadError { fields["error"] = error.message }
        if let evalResult { fields["eval"] = evalResult }
        if let script = evalScript, !state.isLoading, let url = state.url, url != evaluatedURL {
            evaluatedURL = url
            Task { [weak self] in
                let result: String
                do { result = String(describing: try await tab.evaluate(script)) } catch { result = "error: \(error)" }
                self?.evalResult = result
                self?.report()
            }
        }
        if let extensions = tab as? any BrowserExtensionActionHosting {
            fields["extensions"] = extensions.extensionActions.map { ["id": $0.id, "name": $0.name, "badge": $0.badge] }
            if openExtension, !state.isLoading, let first = extensions.extensionActions.first {
                openExtension = false
                let width = tab.contentView.bounds.width
                extensions.runExtensionAction(first.id, anchor: CGRect(x: width - 40, y: 0, width: 32, height: 32))
                fields["openedExtension"] = first.id
            }
        }
        Self.writeReport(fields, to: reportURL)
    }

    private static func writeReport(_ fields: [String: Any], to url: URL?) {
        guard let url, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
