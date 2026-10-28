public import Foundation
import AppKit
import CmuxNextCompatAppKit
public import CmuxNextWakeups

/// A page's links to other apps (mailto:, tel:, an app's own scheme), from a
/// click in the main frame, in both engines (cx-d0d.22). A well-known scheme
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

    /// The app's Launch Services answers (the App sets them at launch): which app opens a scheme is asked on the
    /// system lane and kept per scheme. Nil opens nothing.
    public var queries: WorkspaceQueries?

    /// The name of the app that opens `scheme` links (`url` is one of them), nil when none does; read on the system
    /// lane (Launch Services, then the app's display name from disk).
    nonisolated static func handlerName(scheme: String, url: URL) -> WorkspaceQuery<String?> {
        WorkspaceQuery(id: "browser.externalApp." + scheme, refreshes: true) { system in
            system.defaultApplication(toOpen: url).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
        }
    }

    /// Opens `url`, clicked on the page at `page`, in its app, or asks first
    /// through `ask` (the tab's prompt bar: kind, origin, answer). Which app
    /// opens it is known at once when kept, else when Launch Services answers.
    func open(_ url: URL, from page: URL?,
              ask: @escaping (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) {
        guard let scheme = url.scheme?.lowercased(), let queries else { return }
        queries.value(Self.handlerName(scheme: scheme, url: url), priority: .userBlocking) { [weak self] name in
            guard let self, let name else { return }
            decide(url, scheme: scheme, app: name, from: page, ask: ask)
        }
    }

    private func decide(_ url: URL, scheme: String, app name: String, from page: URL?,
                        ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) {
        let site = page.flatMap(PageInfoSite.origin(of:)) ?? ""
        guard !Self.wellKnownSchemes.contains(scheme), !alwaysAllowed(scheme, for: site) else { return launch(url) }
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
