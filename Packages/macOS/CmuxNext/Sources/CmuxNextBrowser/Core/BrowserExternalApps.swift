public import Foundation
import AppKit
import CmuxNextCompat

/// A page's links to other apps (mailto:, tel:, an app's own scheme), from a
/// click in the main frame, in both engines (cx-d0d.22). A cmux sign-in
/// return also reaches this path after a redirect or script navigation.
/// A well-known scheme
/// opens in its app at once; any other asks first in the tab's prompt bar,
/// inline over the page, never a dialog: Open, Cancel, and "Always allow"
/// for the site, remembered (user defaults; never for a page with no
/// origin, which would share one choice). A scheme no app opens does
/// nothing. In DEBUG builds launched with
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

    /// Opens a main-frame link in its app, or asks first through the tab's
    /// prompt bar. Only a cmux sign-in return can arrive without a gesture;
    /// it still needs the same app-opening consent as a clicked link.
    func open(_ url: URL, from page: URL?, userGesture: Bool = true,
              ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) {
        guard userGesture || Self.isSignInReturn(url) else { return }
        guard let scheme = url.scheme?.lowercased(), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let site = page.flatMap(PageInfoSite.origin(of:)) ?? ""
        guard !Self.wellKnownSchemes.contains(scheme), !alwaysAllowed(scheme, for: site) else { return launch(url) }
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

    /// Classic's default-browser fallback returns to its own registered
    /// scheme, including isolated dev tags. Other cmux links still require
    /// a click, as do scripts trying to open an unrelated app.
    private static func isSignInReturn(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "cmux" || scheme.hasPrefix("cmux-") else { return false }
        if let host = url.host, !host.isEmpty {
            return host.lowercased() == "auth-callback" && (url.path.isEmpty || url.path == "/")
        }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "auth-callback"
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
