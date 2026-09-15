import Foundation

/// A device-management policy cmux honors when an administrator forces it
/// through a macOS configuration profile (MDM "Custom Settings" payload).
///
/// The raw value is the preference key an administrator sets in the
/// ``ManagedDevicePolicy/releasePayloadDomain`` preference domain. Policy
/// keys are deliberately separate from the user-facing settings catalog:
/// a managed policy is tier-0 — it wins over environment variables, user
/// `UserDefaults`, `cmux.json` imports, and built-in defaults — and it can
/// never be changed from inside the app.
public enum ManagedDevicePolicyKey: String, CaseIterable, Sendable {
    /// Disables every embedded-browser surface: browser panes and tabs,
    /// terminal-link interception, and browser creation from automation,
    /// layouts, and session restore.
    case disableEmbeddedBrowser = "DisableEmbeddedBrowser"

    /// Disables the Mac acting as a remote view/control host for the cmux
    /// iOS companion app: the Iroh host runtime, the legacy TCP pairing
    /// listener, connection admission, and device pairing.
    case disableRemoteControl = "DisableRemoteControl"

    /// Disables cmux Cloud Machines and the cmux-managed private network. This
    /// is a tier-0 administrator gate: the sidebar, Settings, palette, session
    /// restore, the surface registry, Cloud VM service calls, the tunnel, and
    /// CLI/socket commands all fail closed while it is enforced.
    case disableCloud = "DisableCloud"

    /// Disables cmux-created remote connections: SSH, Mosh, remote tmux, and
    /// the remote registry, from every entry point (CLI, palette, menus,
    /// session restore, automation). Cloud Machines attach over the same
    /// mechanism, so this key gates them too; ``disableCloud`` remains the key
    /// for disabling Cloud as a product. Terminals on this Mac are unaffected,
    /// and a user's own `ssh` typed into a shell is out of scope by design.
    case disableRemoteConnections = "DisableRemoteConnections"

    /// Disables cmux-mediated file transfer: drag-and-drop and pasted-image
    /// uploads into remote terminals, the configured custom upload command,
    /// and Cloud VM push/pull. Local drops into local terminals still work,
    /// and a user's own `scp` in a shell is out of scope by design.
    case disableFileTransfer = "DisableFileTransfer"

    /// Disables cmux-managed Iroh networking: the host runtime, its relay
    /// traffic, and the client-side connectivity subscriber. Local terminal
    /// work is unaffected. ``disableRemoteControl`` disables the Mac as an
    /// iOS remote-control host specifically; this key disables the Iroh
    /// transport itself, including the paths that are not remote control.
    case disableIrohNetworking = "DisableIrohNetworking"

    /// Disables analytics and crash reporting (PostHog, Sentry) and the remote
    /// feature-flag fetch, all of which carry the install's anonymous id off
    /// the Mac. Read once at launch, like the user opt-in it overrides.
    case disableTelemetry = "DisableTelemetry"

    /// Disables Sparkle: no scheduled or launch-time update checks and no
    /// downloads, and "Check for Updates…" explains the managed state. Read
    /// at launch; the fleet's MDM deploys app versions instead.
    case disableAutoUpdate = "DisableAutoUpdate"

    /// Disables the `webhook` action of automation rules, which posts event
    /// payloads with caller-supplied headers to any http(s) URL.
    case disableAutomationWebhooks = "DisableAutomationWebhooks"

    /// Disables the embedded browser's click-through on certificate errors:
    /// the error page offers no bypass, and no earlier grant is honored.
    case disableTLSTrustBypass = "DisableTLSTrustBypass"

    /// Disables Computer Use: agent launches never receive the tools, the
    /// helper stops, and the Settings toggle locks.
    case disableComputerUse = "DisableComputerUse"

    /// Disables interpreted custom sidebars from `~/.config/cmux/sidebars`
    /// (user- or agent-authored code that can dispatch `cmux(...)` commands).
    case disableCustomSidebars = "DisableCustomSidebars"

    /// Disables uploading local AI credentials (Claude/Codex OAuth tokens,
    /// Anthropic/OpenAI API keys) to the cmux tenant: `aiAccounts.upload` and
    /// the coderouter upstream-account writes. Independent of ``disableCloud``,
    /// which already covers both families.
    case disableAICredentialUpload = "DisableAICredentialUpload"

    /// Restricts embedded-browser top-level navigations to the administrator's
    /// URL patterns. An empty forced array denies every external web origin
    /// while preserving cmux-owned internal documents. Loopback origins and
    /// local `file:` documents stay available by default under a forced list;
    /// ``browserAllowLocalhost`` and ``browserAllowLocalFiles`` turn those
    /// defaults off.
    case browserURLAllowlist = "BrowserURLAllowlist"

    /// Whether the embedded browser may open loopback origins (`localhost`,
    /// `*.localhost`, `127.0.0.1`, `::1`, `0.0.0.0`, on any port) without a
    /// ``browserURLAllowlist`` entry. An allow-style key: it defaults to
    /// `true`, and a profile forces `false` to block local development
    /// servers, even ones a list names explicitly.
    case browserAllowLocalhost = "BrowserAllowLocalhost"

    /// Whether the embedded browser may show local `file:` documents (files
    /// opened through cmux, dropped onto a browser pane, or linked from
    /// another local document). An allow-style key: it defaults to `true`,
    /// and a profile forces `false` to block local files whether or not a
    /// ``browserURLAllowlist`` is forced.
    case browserAllowLocalFiles = "BrowserAllowLocalFiles"

    /// The keys whose enforced state is "forced to `false`" rather than
    /// "forced to `true`". Every other Boolean key is a `Disable…` switch.
    public static let allowStyleKeys: Set<ManagedDevicePolicyKey> = [
        .browserAllowLocalhost,
        .browserAllowLocalFiles,
    ]
}
