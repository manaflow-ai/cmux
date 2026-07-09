import Foundation

/// One entry in the `~/.config/cmux/extensions.json` lockfile: what is
/// installed, where it came from, the pinned commit, and the consent
/// fingerprint the user approved.
public struct DockExtensionInstallRecord: Codable, Equatable, Sendable, Identifiable {
    /// The extension id (the manifest's `id`).
    public let id: String

    /// Where the extension came from (GitHub shorthand or linked directory).
    public var source: DockExtensionSource

    /// The pinned commit SHA the managed checkout is detached at. `nil` for
    /// linked development extensions, which have no managed checkout.
    public var pinnedSha: String?

    /// The user-requested ref (`--ref`), when one was given. Updates re-resolve
    /// this ref; absent means the remote default branch.
    public var ref: String?

    /// When this record was installed or last updated.
    public var installedAt: Date

    /// Whether the extension's panes are offered in launchers. Disabling keeps
    /// the checkout and consent but hides the panes.
    public var enabled: Bool

    /// ``DockExtensionManifest/consentFingerprint(pinnedSha:)`` of the
    /// consented commit + commands. A mismatch against the checkout's current
    /// manifest flags the extension as needing re-consent.
    public var consentFingerprint: String

    /// Creates a lockfile record.
    public init(
        id: String,
        source: DockExtensionSource,
        pinnedSha: String?,
        ref: String? = nil,
        installedAt: Date,
        enabled: Bool = true,
        consentFingerprint: String
    ) {
        self.id = id
        self.source = source
        self.pinnedSha = pinnedSha
        self.ref = ref
        self.installedAt = installedAt
        self.enabled = enabled
        self.consentFingerprint = consentFingerprint
    }
}
