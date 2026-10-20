public import Foundation

/// A Chromium runtime pack that is installed and verified on this Mac.
///
/// Its folder is `<root>/<key>/` and holds the runtime folder and
/// `installed.json` (the pin it was checked against). The folder exists only
/// once the install finished: it is renamed into place, then the record is
/// written.
public struct ChromiumRuntimeInstallation: Sendable, Equatable {
    /// The pin the pack was verified against.
    public var pin: ChromiumRuntimePin
    /// `<root>/<key>/`.
    public var directory: URL

    /// Creates an installation value for `pin` in `directory`.
    public init(pin: ChromiumRuntimePin, directory: URL) {
        self.pin = pin
        self.directory = directory
    }

    /// The runtime folder (`<root>/<key>/<folder>`): the framework, the shim
    /// and the helper apps side by side, what `CEFRuntimeLayout.at` takes.
    /// Flat, not an app bundle: the helper sandbox can read only this folder
    /// (the `cmux_runtime_outside_bundle` CEF patch), so the app stays
    /// Chromium's main bundle (plans/cmux-next/bundle-size-DESIGN.md 6.1).
    public var frameworksDirectory: URL { directory.appending(path: pin.folder, directoryHint: .isDirectory) }

    /// The record file name inside the install folder.
    static let recordName = "installed.json"
}
