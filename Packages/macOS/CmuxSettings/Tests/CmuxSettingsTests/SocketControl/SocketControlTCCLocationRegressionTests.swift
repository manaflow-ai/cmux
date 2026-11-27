import Foundation
import Testing

@testable import CmuxSettings

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5146.
///
/// The control socket directory and the socket password file are read by the
/// separately code-signed `cmux` CLI on every agent session-start/stop hook. On
/// macOS Sequoia, a non-sandboxed process reaching into another app's data under
/// `~/Library/Application Support`, `~/Library/Containers`, or
/// `~/Library/Group Containers` triggers the "would like to access data from
/// other apps" TCC prompt. These resolved paths must therefore live OUTSIDE
/// those TCC-protected app-data roots.
///
/// These assert the real resolved paths (runtime behavior, not source text), so
/// they fail while the files resolve under Application Support and pass once they
/// move to the non-protected state directory.
@Suite struct SocketControlTCCLocationRegressionTests {
    private func expectOutsideTCCAppData(_ path: String) {
        #expect(!path.contains("/Library/Application Support"))
        #expect(!path.contains("/Library/Containers"))
        #expect(!path.contains("/Library/Group Containers"))
    }

    @Test func controlSocketDirectoryIsOutsideTCCProtectedAppData() throws {
        let directory = try #require(SocketControlSettings.stableSocketDirectoryURL()?.path)
        expectOutsideTCCAppData(directory)
        #expect(directory.hasSuffix("/.local/state/cmux"))
    }

    @Test func socketPasswordFileIsOutsideTCCProtectedAppData() throws {
        let path = try #require(SocketControlPasswordStore.defaultPasswordFileURL(fileManager: .default)?.path)
        expectOutsideTCCAppData(path)
        #expect(path.hasSuffix("/.local/state/cmux/socket-control-password"))
    }
}
