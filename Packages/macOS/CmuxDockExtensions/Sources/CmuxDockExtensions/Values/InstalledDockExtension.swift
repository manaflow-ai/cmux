import Foundation

/// A lockfile record projected against what is actually on disk: the manifest
/// read from the checkout (or linked directory) plus a health status. This is
/// what launchers and Settings render.
public struct InstalledDockExtension: Equatable, Sendable, Identifiable {
    /// Health of the on-disk installation.
    public enum Status: Equatable, Sendable {
        /// Manifest present and matching the consented fingerprint.
        case ok
        /// The checkout or its manifest is missing/unreadable.
        case manifestUnavailable(String)
        /// The manifest on disk no longer matches the consented fingerprint;
        /// panes are withheld until the user re-consents (reinstall/update).
        case needsReconsent
    }

    /// The lockfile record backing this projection.
    public let record: DockExtensionInstallRecord

    /// The manifest read from disk, when readable.
    public let manifest: DockExtensionManifest?

    /// The extension root: the managed checkout (plus manifest subdirectory,
    /// when the source names one) or the linked directory.
    public let rootDirectory: URL

    /// On-disk health.
    public let status: Status

    /// The extension id.
    public var id: String { record.id }

    /// Whether this is a linked local development extension.
    public var isLinked: Bool { record.source.isLocal }

    /// Display name: the manifest name when readable, else the id.
    public var displayName: String { manifest?.name ?? record.id }

    /// SF Symbol for launchers and Settings rows.
    public var iconSystemName: String {
        manifest?.iconSystemName ?? DockExtensionManifest.defaultIconSystemName
    }

    /// The panes launchers may offer: only for enabled, healthy extensions,
    /// filtered to the running platform.
    public var launchablePanes: [DockExtensionPane] {
        guard record.enabled, status == .ok, let manifest else { return [] }
        return manifest.panesForCurrentPlatform
    }

    /// Creates a projection value.
    public init(
        record: DockExtensionInstallRecord,
        manifest: DockExtensionManifest?,
        rootDirectory: URL,
        status: Status
    ) {
        self.record = record
        self.manifest = manifest
        self.rootDirectory = rootDirectory
        self.status = status
    }
}
