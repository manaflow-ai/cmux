// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation
import CmuxNextCompat

/// The signed cmux Computer Use bundle embedded in this app. The daemon stages and starts its
/// supervisor. The app uses the bundle's location for onboarding and permission settings.
public nonisolated struct ComputerUseRemoteBundle: Sendable, Equatable {
    /// The `cmux-remote` executable.
    public var executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// The `.app` that holds the executable.
    public var appURL: URL {
        executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The supervisor executable in the embedded cmux Computer Use bundle.
    public static func embedded(bundle: Bundle = .main) -> ComputerUseRemoteBundle? {
        for name in ["cmux Computer Use.app", "cmux Computer Use (dev).app"] {
            let url = bundle.bundleURL.appending(path: "Contents/Library/\(name)/Contents/MacOS/cmux-remote")
            if FileManager.checked.isExecutableFile(atPath: url.path) { return ComputerUseRemoteBundle(executable: url) }
        }
        return nil
    }
}
