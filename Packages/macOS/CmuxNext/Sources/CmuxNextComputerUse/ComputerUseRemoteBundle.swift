// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation
import CmuxNextCompat

/// cmux Remote as this app embeds it (docs/cmux-remote.md): the signed host whose Computer Use
/// worker runs the cmux Computer Use engine. The cmux-tui daemon copies it out of the app and
/// starts it; the app only needs to know whether this build has one, and where.
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

    /// cmux Remote's executable in this app's bundle (`Contents/Library`), or nil.
    public static func embedded(bundle: Bundle = .main) -> ComputerUseRemoteBundle? {
        for name in ["cmux Remote.app", "cmux Remote (dev).app"] {
            let url = bundle.bundleURL.appending(path: "Contents/Library/\(name)/Contents/MacOS/cmux-remote")
            if FileManager.checked.isExecutableFile(atPath: url.path) { return ComputerUseRemoteBundle(executable: url) }
        }
        return nil
    }
}
