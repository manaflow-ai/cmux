public import Foundation
import AppKit
import CmuxNextCompat

/// A page's links to other apps (mailto:, tel:, an app's own scheme), from a
/// click in the main frame, in both engines (cx-d0d.22). A non-gesture
/// navigation (such as an OAuth return) reaches this path too and must still
/// ask before opening its app, without inheriting a saved permission from the
/// previously committed page. A well-known scheme opens in its app at once
/// from a click; any other asks first in the tab's prompt bar,
/// inline over the page, never a dialog: Open, Cancel, and "Always allow"
/// for the site, remembered (user defaults; never for a page with no
/// origin, which would share one choice). A scheme no app opens does
/// nothing. In DEBUG builds launched with
/// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1` opens are recorded instead, so a
/// live test never starts Mail (`debug.browser.external_opens`).
@MainActor
public final class BrowserExternalApps {
    public static let shared = BrowserExternalApps()

    /// Schemes that open without asking after a click: mail, phone and
    /// messages, and the apps people open from web pages every day (meetings,
    /// chat, editors).
    static let wellKnownSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps",
        "zoommtg", "zoomus", "msteams", "slack", "discord", "spotify",
        "vscode", "vscode-insiders", "cursor", "figma", "linear", "notion",
    ]
    private static let defaultsKey = "CmuxNextBrowser.externalSchemes"
    private let defaults: UserDefaults

    #if DEBUG
    /// The URLs a recording build would have opened, oldest first.
    public private(set) var recorded: [URL] = []
    private let records = ProcessInfo.processInfo.environment["CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS"] == "1"

    public func clearRecorded() {
        recorded.removeAll()
    }
    #endif

    private let appFor: (URL) -> URL?
    private let opener: (URL) -> Void

    init(defaults: UserDefaults = .standard,
         appFor: @escaping (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }) {
        self.defaults = defaults
        self.appFor = appFor
        self.opener = opener
    }

    /// Opens a main-frame link in its app, or asks first through the tab's
    /// prompt bar. Non-gesture navigations always require the app-opening
    /// prompt, including schemes that open immediately from a click.
    func open(_ url: URL, from page: URL?, userGesture: Bool = true,
              asking: (BrowserPromptKind, String) -> Bool = { _, _ in false },
              ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) {
        guard let scheme = url.scheme?.lowercased(), let app = appFor(url) else { return }
        // A non-gesture navigation can be a redirect whose source is the
        // previously committed page, so it cannot safely inherit that site's
        // remembered permission. The empty origin also hides "Always allow"
        // for this one-off handoff.
        let site = userGesture ? page.flatMap(PageInfoSite.origin(of:)) ?? "" : ""
        if userGesture && (Self.wellKnownSchemes.contains(scheme) || alwaysAllowed(scheme, for: site)) {
            return launch(url)
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        ask(.openExternalApp(app: name, scheme: scheme), site) { [weak self] response in
            switch response {
            case .allow:
                self?.allowAlways(scheme, for: site)
                self?.launch(url)
            case .allowOnce:
                self?.launch(url)
            default:
                break
            }
        }
    }

    private func alwaysAllowed(_ scheme: String, for site: String) -> Bool {
        guard !site.isEmpty else { return false }
        return (defaults.dictionary(forKey: Self.defaultsKey)?[site] as? [String])?.contains(scheme) == true
    }

    private func allowAlways(_ scheme: String, for site: String) {
        guard !site.isEmpty else { return }
        var stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let schemes = stored[site] as? [String] ?? []
        guard !schemes.contains(scheme) else { return }
        stored[site] = schemes + [scheme]
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    private func launch(_ url: URL) {
        #if DEBUG
        if records {
            recorded.append(url)
            return
        }
        #endif
        opener(url)
    }
}
