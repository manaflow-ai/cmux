public import Foundation
import AppKit
import CmuxNextCompat

/// A page's links to other apps (mailto:, tel:, an app's own scheme), from a
/// click in the main frame, in both engines (cx-d0d.22). A well-known scheme
/// opens in its app at once; any other asks first in the tab's prompt bar,
/// inline over the page, never a dialog: Open, Cancel, and "Always allow"
/// for the site, remembered (user defaults; never for a page with no
/// origin, which would share one choice). A scheme no app opens does
/// nothing. In a Chromium tab a server redirect to another app (a sign-in
/// returning to its app) always asks. In DEBUG builds launched with
/// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1` opens are recorded instead, so a
/// live test never starts Mail (`debug.browser.external_opens`).
@MainActor
public final class BrowserExternalApps {
    public static let shared = BrowserExternalApps()

    /// Schemes that open without asking: mail, phone and messages, and the
    /// apps people open from web pages every day (meetings, chat, editors).
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Opens `url`, clicked on the page at `page`, in its app, or asks first
    /// through `ask` (the tab's prompt bar: kind, origin, answer). A server
    /// redirect led there when `redirected` (a sign-in returning to its app):
    /// no click started it, so it always asks, even for a well-known scheme,
    /// and offers no "Always allow" (the page that redirected is not `page`).
    func open(_ url: URL, from page: URL?, redirected: Bool = false,
              ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) {
        guard let scheme = url.scheme?.lowercased(), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let site = redirected ? "" : page.flatMap(PageInfoSite.origin(of:)) ?? ""
        if !redirected, Self.wellKnownSchemes.contains(scheme) || alwaysAllowed(scheme, for: site) { return launch(url) }
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
        NSWorkspace.shared.openInBackground(url)
    }
}
