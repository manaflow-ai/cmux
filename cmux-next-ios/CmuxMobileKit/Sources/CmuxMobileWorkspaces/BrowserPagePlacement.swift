#if os(iOS)
import CmuxMobileModel
import Foundation

/// Where a newly opened browser page shows while linked to its Mac: in this iPhone's
/// own web view, or the Mac's browser streamed. Settings → Browser → Open New Pages
/// (`BrowserOpenDefault`) picks the rule; with Automatic the page's address decides:
///
/// | Page | Automatic | Always on iPhone | Always Stream |
/// |---|---|---|---|
/// | Public web page (`https://example.com`) | phone | phone | stream |
/// | HTML file on the Mac (`file:///…/report.html`) | phone (read over the link) | phone | stream |
/// | Site that needs the Mac's sign-in (GitHub, Linear, Google Docs, a `/login` page) | stream | phone | stream |
/// | Mac `localhost:<port>`, the Mac forwards it | phone | phone | stream |
/// | Mac `localhost:<port>`, an older Mac | stream | stream | stream |
/// | Private, LAN or tailnet host (`mac.local`, `*.ts.net`, `10.x`) | stream | phone | stream |
/// | Other Mac-only page (`file:` image or folder, `view-source:`, `chrome:`) | stream | stream | stream |
/// | Blank new tab (`about:blank`, no address yet) | stream | phone | stream |
///
/// Decided once, when the tab first appears; Open on iPhone / Mirror from Mac on the
/// tab's menu changes it afterwards and wins.
public struct BrowserPagePlacement: Equatable, Sendable {
    public enum Target: String, Equatable, Sendable { case phone, stream }

    /// Why, in words the tab's notice and the HTML proof show.
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        case publicPage
        case htmlFile
        case signInSite
        case forwardedLocalhost
        case localhostNotForwarded
        case privateNetwork
        case macOnly
        case blank
        case alwaysPhone
        case alwaysStream
    }

    public var target: Target
    public var reason: Reason

    public init(_ target: Target, _ reason: Reason) {
        self.target = target
        self.reason = reason
    }

    /// The page's kind as the rule reads it.
    public enum PageKind: String, Equatable, Sendable, CaseIterable {
        case blank, publicPage, htmlFile, signInSite, localhost, privateNetwork, macOnly
    }

    public static func kind(of url: URL?) -> PageKind {
        guard let url, url.absoluteString != "about:blank", !url.absoluteString.isEmpty else { return .blank }
        if isMacHTMLFile(url) { return .htmlFile }
        switch PhoneReach(url) {
        case .macOnly: return .macOnly
        case .macLoopback: return .localhost
        case .privateNetwork: return .privateNetwork
        case .web:
            let scheme = url.scheme?.lowercased() ?? ""
            guard ["http", "https"].contains(scheme) else { return .publicPage }
            return needsMacSignIn(url) ? .signInSite : .publicPage
        }
    }

    /// The rule. `forwardsLocalhost`: the page's Mac serves its `localhost` to this iPhone.
    public static func decide(_ url: URL?, preference: BrowserOpenDefault, forwardsLocalhost: Bool) -> BrowserPagePlacement {
        let kind = kind(of: url)
        // What the phone can never load: every rule streams it.
        switch kind {
        case .macOnly: return .init(.stream, .macOnly)
        case .localhost where !forwardsLocalhost: return .init(.stream, .localhostNotForwarded)
        default: break
        }
        switch preference {
        case .stream: return .init(.stream, .alwaysStream)
        case .phone: return .init(.phone, kind == .htmlFile ? .htmlFile : kind == .localhost ? .forwardedLocalhost : .alwaysPhone)
        case .automatic:
            switch kind {
            case .publicPage: return .init(.phone, .publicPage)
            case .htmlFile: return .init(.phone, .htmlFile)
            case .localhost: return .init(.phone, .forwardedLocalhost)
            case .signInSite: return .init(.stream, .signInSite)
            case .privateNetwork: return .init(.stream, .privateNetwork)
            case .blank: return .init(.stream, .blank)
            case .macOnly: return .init(.stream, .macOnly)
            }
        }
    }

    /// An HTML file on the Mac (an agent's report, `cmux open report.html`): this iPhone
    /// reads it over the link's `file-preview` service and shows it in its own web view.
    public static func isMacHTMLFile(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "file" else { return false }
        return ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }

    /// Hosts whose pages are the person's signed-in session on the Mac: on a phone with
    /// no cookies they show a sign-in page or a 404, so Automatic streams them.
    static let signInHosts: [String] = [
        "github.com", "gitlab.com", "bitbucket.org", "linear.app", "vercel.com", "netlify.com",
        "notion.so", "notion.site", "figma.com", "slack.com", "app.slack.com", "discord.com",
        "docs.google.com", "drive.google.com", "mail.google.com", "calendar.google.com", "console.cloud.google.com",
        "accounts.google.com", "appstoreconnect.apple.com", "developer.apple.com", "icloud.com",
        "console.aws.amazon.com", "portal.azure.com", "dashboard.stripe.com", "app.datadoghq.com",
        "sentry.io", "atlassian.net", "1password.com", "cloudflare.com", "dash.cloudflare.com",
        "chatgpt.com", "claude.ai", "console.anthropic.com", "platform.openai.com",
        "x.com", "twitter.com", "linkedin.com", "facebook.com", "instagram.com",
    ]

    /// First labels of hosts that are dashboards or sign-in pages wherever they live.
    static let signInHostPrefixes: [String] = [
        "login.", "signin.", "auth.", "accounts.", "account.", "sso.", "id.", "admin.", "dashboard.", "console.", "portal.",
    ]

    /// Paths that are a sign-in step (an OAuth hop, `/login`).
    static let signInPathMarkers: [String] = ["/login", "/signin", "/sign-in", "/sign_in", "/oauth", "/sso", "/auth/", "/authorize", "/saml"]

    static func needsMacSignIn(_ url: URL) -> Bool {
        guard let raw = url.host(percentEncoded: false)?.lowercased() else { return false }
        let host = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        if signInHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if signInHostPrefixes.contains(where: host.hasPrefix) { return true }
        let path = url.path(percentEncoded: false).lowercased()
        return signInPathMarkers.contains { marker in
            marker.hasSuffix("/") ? path.hasPrefix(marker) : path == marker || path.hasPrefix(marker + "/")
        }
    }

    /// The tab notice after a page opened on this iPhone by itself (nil: no notice).
    public func notice(macName: String) -> String? {
        guard target == .phone else { return nil }
        switch reason {
        case .htmlFile: return String(localized: "Opened on this iPhone from \(macName).")
        default: return String(localized: "Opened on this iPhone. Sign-ins on \(macName) don't carry over.")
        }
    }
}
#endif
