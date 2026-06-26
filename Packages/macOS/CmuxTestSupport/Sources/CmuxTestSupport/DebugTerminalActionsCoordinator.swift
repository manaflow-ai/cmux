#if DEBUG
import Foundation

/// Orchestrates the Debug menu's terminal-tab openers.
///
/// The Debug menu exposes five openers: stream a large scrollback payload into a
/// new tab, stream a Lorem payload into a new tab, open a React or Solid agent
/// session in the selected workspace, and create one tinted "Debug Color"
/// workspace per palette color. This coordinator owns each opener's logic — the
/// payload selection, the React-vs-Solid renderer dispatch, and the
/// color-comparison create-or-reuse loop — none of which touches an app type.
/// The operations that touch live `Workspace` / `TabManager` /
/// terminal-surface state are inverted behind ``DebugTerminalActionsHosting``,
/// which the app target conforms.
///
/// The bodies are a faithful lift of the former `AppDelegate` menu actions
/// (`openDebugScrollbackTab`, `openDebugLoremTab`, `openDebugAgentSessionReact`,
/// `openDebugAgentSessionSolid`, the private `openDebugAgentSession(rendererKind:)`,
/// and `openDebugColorComparisonWorkspaces`): the same guards, the same payload
/// builders (``DebugTerminalTabContent``), and the same title/color loop are
/// preserved. The `@objc` selector methods stay on `AppDelegate` as one-line
/// forwarders, since NSMenu target-action must resolve on the app delegate.
///
/// Isolation: `@MainActor`, because every opener drives main-actor state through
/// the host. The host is held weakly — it is owned by the app delegate that also
/// owns this coordinator, so a strong ref would create a retain cycle.
@MainActor
public final class DebugTerminalActionsCoordinator {
    /// The title prefix every color-comparison workspace carries (legacy
    /// `AppDelegate.debugColorWorkspaceTitlePrefix`).
    public static let colorWorkspaceTitlePrefix = "Debug Color - "

    private weak var host: (any DebugTerminalActionsHosting)?

    /// Creates a coordinator bound to `host`.
    public init(host: any DebugTerminalActionsHosting) {
        self.host = host
    }

    /// Creates a new tab and streams a scrollback-filling payload sized to the
    /// host's Ghostty scrollback limit (legacy `openDebugScrollbackTab`).
    public func openScrollbackTab() {
        guard let host, host.canRunDebugTerminalActions else { return }
        guard let tabId = host.addDebugTab() else { return }
        let command = DebugTerminalTabContent.scrollback(
            scrollbackLimit: host.ghosttyScrollbackLimit
        ).text
        host.sendDebugText(command, toTab: tabId)
    }

    /// Creates a new tab and streams the fixed Lorem payload (legacy
    /// `openDebugLoremTab`).
    public func openLoremTab() {
        guard let host, host.canRunDebugTerminalActions else { return }
        guard let tabId = host.addDebugTab() else { return }
        let payload = DebugTerminalTabContent.lorem.text
        host.sendDebugText(payload, toTab: tabId)
    }

    /// Opens an agent session with `rendererKind` in the selected workspace's
    /// focused pane (legacy `openDebugAgentSessionReact` / `openDebugAgentSessionSolid`
    /// forwarding into the private `openDebugAgentSession(rendererKind:)`).
    public func openAgentSession(rendererKind: DebugAgentSessionRendererKind) {
        guard let host else { return }
        host.openDebugAgentSession(rendererKind: rendererKind)
    }

    /// Creates (or reuses) one tinted workspace per tab-color palette entry,
    /// titled `"Debug Color - <name>"` (legacy `openDebugColorComparisonWorkspaces`).
    public func openColorComparisonWorkspaces() {
        guard let host, host.canRunDebugTerminalActions else { return }

        let palette = host.debugColorComparisonPalette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: UUID] = [:]
        for tab in host.debugTabSnapshots() {
            guard let title = tab.customTitle,
                  title.hasPrefix(Self.colorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab.id
        }

        for entry in palette {
            let title = "\(Self.colorWorkspaceTitlePrefix)\(entry.name)"
            let targetTabId: UUID
            if let existing = existingByTitle[title] {
                targetTabId = existing
            } else if let created = host.addDebugTab() {
                targetTabId = created
            } else {
                continue
            }
            host.setDebugTabCustomTitle(tabId: targetTabId, title: title)
            host.setDebugTabColor(tabId: targetTabId, hex: entry.hex)
        }
    }
}
#endif
