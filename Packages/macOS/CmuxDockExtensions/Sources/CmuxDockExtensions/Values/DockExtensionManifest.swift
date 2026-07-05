import Foundation

/// The parsed `cmux-extension.json` manifest — the contract between cmux and a
/// Dock TUI extension.
///
/// The manifest format deliberately mirrors herdr's `herdr-plugin.toml` field
/// semantics (required `id`/`name`/`version`, optional `description`/
/// `minCmuxVersion`/`platforms`, argv-array `build` steps and `panes`), carried
/// as JSON to match the rest of cmux's config surface (`cmux.json`,
/// `dock.json`). All commands are argv arrays; there is no shell expansion in
/// the manifest itself.
///
/// Instances are produced by ``DockExtensionManifest/parse(data:)`` (see
/// `DockExtensionManifest+Parsing.swift`), which validates every field and
/// records unknown top-level keys as ``unknownTopLevelKeys`` so manifests
/// written for a newer cmux degrade gracefully instead of failing to install.
public struct DockExtensionManifest: Equatable, Sendable {
    /// The manifest file name looked up at an extension's root (or the
    /// `owner/repo/subdir` subdirectory for subdirectory installs).
    public static let manifestFileName = "cmux-extension.json"

    /// The only manifest schema version this build of cmux understands.
    public static let supportedManifestVersion = 1

    /// Hard cap on the manifest file size; larger files are rejected before
    /// parsing.
    public static let maximumFileSize = 64 * 1024

    /// The platform identifier manifests use to target this app.
    public static let currentPlatform = "macos"

    /// Manifest schema version (`manifestVersion`). Always
    /// ``supportedManifestVersion`` for successfully parsed manifests.
    public let manifestVersion: Int

    /// Stable extension identifier. ASCII letters, digits, `.`, `_`, `:`, `-`;
    /// at most 64 characters and never dots only. Also used for the on-disk
    /// checkout/config/state directory names.
    public let id: String

    /// Human-readable extension name shown in Settings, the command palette,
    /// and Dock tabs.
    public let name: String

    /// Author-declared extension version string (informational; installs are
    /// pinned by commit SHA, not by this field).
    public let version: String

    /// Optional one-line description shown in Settings and the consent sheet.
    public let description: String?

    /// Optional minimum cmux app version. Installation is refused when the
    /// running app is older, mirroring herdr's `min_herdr_version`.
    public let minCmuxVersion: DockExtensionVersion?

    /// Optional platform allowlist for the whole extension (e.g. `["macos"]`).
    /// `nil` means every platform.
    public let platforms: [String]?

    /// Optional SF Symbol name shown next to the extension in cmux UI.
    /// Falls back to ``defaultIconSystemName`` when absent.
    public let icon: String?

    /// Build steps run once at install/update time (never for linked dev
    /// extensions), in manifest order, from the extension root.
    public let build: [DockExtensionBuildStep]

    /// The TUI panes this extension contributes to the Dock. At least one.
    public let panes: [DockExtensionPane]

    /// Top-level manifest keys this cmux version does not understand (for
    /// example a future `actions` section). Surfaced as consent-sheet warnings
    /// rather than hard errors.
    public let unknownTopLevelKeys: [String]

    /// SF Symbol used when a manifest declares no ``icon``.
    public static let defaultIconSystemName = "puzzlepiece.extension"

    /// The SF Symbol to display for this extension.
    public var iconSystemName: String {
        icon ?? Self.defaultIconSystemName
    }

    /// Whether a manifest-level or item-level `platforms` list includes the
    /// running platform. A `nil` list means "all platforms".
    public static func appliesToCurrentPlatform(_ platforms: [String]?) -> Bool {
        guard let platforms else { return true }
        return platforms.contains { $0.caseInsensitiveCompare(currentPlatform) == .orderedSame }
    }

    /// Whether the extension itself targets the running platform.
    public var appliesToCurrentPlatform: Bool {
        Self.appliesToCurrentPlatform(platforms)
    }

    /// The panes that apply to the running platform, in manifest order.
    public var panesForCurrentPlatform: [DockExtensionPane] {
        guard appliesToCurrentPlatform else { return [] }
        return panes.filter { Self.appliesToCurrentPlatform($0.platforms) }
    }

    /// The build steps that apply to the running platform, in manifest order.
    public var buildStepsForCurrentPlatform: [DockExtensionBuildStep] {
        build.filter { Self.appliesToCurrentPlatform($0.platforms) }
    }

    /// The pane with the given local id, if declared.
    public func pane(withId paneId: String) -> DockExtensionPane? {
        panes.first { $0.id == paneId }
    }

    /// Memberwise initializer, primarily for tests; production manifests come
    /// from ``parse(data:)``.
    public init(
        manifestVersion: Int,
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        minCmuxVersion: DockExtensionVersion? = nil,
        platforms: [String]? = nil,
        icon: String? = nil,
        build: [DockExtensionBuildStep] = [],
        panes: [DockExtensionPane],
        unknownTopLevelKeys: [String] = []
    ) {
        self.manifestVersion = manifestVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.minCmuxVersion = minCmuxVersion
        self.platforms = platforms
        self.icon = icon
        self.build = build
        self.panes = panes
        self.unknownTopLevelKeys = unknownTopLevelKeys
    }
}
