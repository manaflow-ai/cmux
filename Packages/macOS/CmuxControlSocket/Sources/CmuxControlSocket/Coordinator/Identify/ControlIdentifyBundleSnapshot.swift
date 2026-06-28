/// The app-bundle path reads for the `system.identify` payload tail (the legacy
/// `v2Identify` `bundle_identifier` / `app_bundle_path` / `app_executable_path`
/// / `app_cli_path` block), produced by ``ControlIdentifyContext``.
///
/// Only ``bundlePath`` is unconditional; the others are emitted only when
/// present, matching the legacy conditional inserts.
public struct ControlIdentifyBundleSnapshot: Sendable {
    /// `Bundle.main.bundleIdentifier` (emitted as `bundle_identifier` when set).
    public let bundleIdentifier: String?
    /// `Bundle.main.bundleURL.path` (always emitted as `app_bundle_path`).
    public let bundlePath: String
    /// `Bundle.main.executableURL?.path` (emitted as `app_executable_path`).
    public let executablePath: String?
    /// The bundled `bin/cmux` resource path (emitted as `app_cli_path`).
    public let cliPath: String?

    /// Creates a bundle-path snapshot.
    public init(
        bundleIdentifier: String?,
        bundlePath: String,
        executablePath: String?,
        cliPath: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.cliPath = cliPath
    }
}
