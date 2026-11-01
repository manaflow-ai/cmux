// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxNextComputerUse
import Foundation

extension ComputerUseHelperStaging {
    /// A staging for helper lifecycle tests, whose helper bundle does not
    /// exist: the copy is an empty folder under `root`, every stamp matches
    /// and every signature check passes. ComputerUseHelperStagingTests covers
    /// the real copy and its checks.
    static func passing(root: URL) -> ComputerUseHelperStaging {
        let operations = Operations(
            copy: { _, destination in
                (try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)) != nil
            },
            stamp: { _ in Stamp(version: "1", codeDirectoryHash: Data("test".utf8)) },
            verify: { _, _ in true },
            makeRunningCheck: { _ in { _ in true } })
        // The staging checks every folder below an existing home.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The temporary folder sits behind a symlink (/var); compare paths as given.
        var fileSystem = FileSystem()
        fileSystem.resolve = { $0.absoluteURL.path }
        return ComputerUseHelperStaging(folder: Self.root(home: root).appending(path: "next-test", directoryHint: .isDirectory),
                                        home: root, operations: operations, fileSystem: fileSystem)
    }
}
