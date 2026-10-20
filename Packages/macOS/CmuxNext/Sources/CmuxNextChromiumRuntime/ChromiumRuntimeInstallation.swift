public import Foundation

/// A Chromium runtime pack that is installed and verified on this Mac.
///
/// Its folder is `<root>/<key>/` and holds the wrapper app and
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

    /// The wrapper app (`<root>/<key>/<wrapper>`): Chromium's main bundle.
    public var wrapperApp: URL { directory.appending(path: pin.wrapper, directoryHint: .isDirectory) }

    /// The wrapper's `Contents/Frameworks`: what `CEFRuntimeLayout.locate`
    /// takes (framework, shim and helpers).
    public var frameworksDirectory: URL { wrapperApp.appending(path: "Contents/Frameworks", directoryHint: .isDirectory) }

    /// The record file name inside the install folder.
    static let recordName = "installed.json"
}
