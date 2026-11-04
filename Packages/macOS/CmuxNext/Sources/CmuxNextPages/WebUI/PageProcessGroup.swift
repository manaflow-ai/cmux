import Foundation

/// The renderer a first-party page shares (plans/cmux-next/chrome-parity/p13-webui.md 3.B). Chrome lets
/// WebUI pages share a renderer only when their process lock says so (`content/browser/site_info.cc`,
/// `IsWebUIAndUsesTLDForProcessLockURL`), and keeps untrusted content in `chrome-untrusted://` documents,
/// never in a process with stronger bindings (`content/public/common/url_constants.h`,
/// `kChromeUIUntrustedScheme`). A cmux group is the same rule: pages share only with pages of their
/// capability class (what a compromised renderer could reach through the page).
public nonisolated enum PageProcessGroup: String, Sendable, Hashable, CaseIterable {
    /// The agent page: New Tab and every chat, one origin.
    case agent
    /// Pages that write app state and show only app data.
    case privileged
    /// Pages that show repository files or remote content and only read.
    case viewer
    /// Host power, undeclared ops, or outside content with actions: one renderer each.
    case solo
    /// Stored secrets: one renderer each, never shared.
    case secrets

    /// Whether the group's pages share one renderer; `solo` and `secrets` pages each get their own.
    public var sharesRenderer: Bool {
        switch self {
        case .agent, .privileged, .viewer: true
        case .solo, .secrets: false
        }
    }
}
