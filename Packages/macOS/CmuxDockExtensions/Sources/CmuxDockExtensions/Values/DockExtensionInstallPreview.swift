import Foundation

/// Everything the consent sheet shows before anything runs: the source, the
/// resolved pinned commit, the parsed manifest (with its exact build/pane
/// commands), and any warnings. Produced by
/// `DockExtensionsStore.preview(...)`; a confirmed preview is what
/// `DockExtensionsStore.install(_:)` executes.
public struct DockExtensionInstallPreview: Equatable, Sendable {
    /// What confirming this preview will do.
    public enum Kind: Equatable, Sendable {
        /// First install of this extension id.
        case install
        /// Reinstall/update of an already-installed id from the same source.
        /// `previousSha` is the currently pinned commit (`nil` if unchanged
        /// records were linked).
        case update(previousSha: String?)
    }

    /// Where the extension comes from.
    public let source: DockExtensionSource

    /// The commit SHA this install pins to. Always present for GitHub sources.
    public let resolvedSha: String?

    /// The user-requested ref, when one was given.
    public let ref: String?

    /// The parsed manifest as staged.
    public let manifest: DockExtensionManifest

    /// The staged checkout on disk (deleted on cancel, moved into place on
    /// confirm).
    public let stagingDirectory: URL?

    /// Human-readable warnings (unknown manifest sections, platform notes).
    public let warnings: [String]

    /// Install vs update.
    public let kind: Kind

    /// The consent fingerprint that confirming this preview records.
    public var consentFingerprint: String {
        manifest.consentFingerprint(pinnedSha: resolvedSha)
    }

    /// Creates a preview value.
    public init(
        source: DockExtensionSource,
        resolvedSha: String?,
        ref: String?,
        manifest: DockExtensionManifest,
        stagingDirectory: URL?,
        warnings: [String],
        kind: Kind
    ) {
        self.source = source
        self.resolvedSha = resolvedSha
        self.ref = ref
        self.manifest = manifest
        self.stagingDirectory = stagingDirectory
        self.warnings = warnings
        self.kind = kind
    }
}
