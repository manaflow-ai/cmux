import CmuxNextCompat
import Foundation
@testable import CmuxNextHomeEngine
import Testing

/// The Chief's brain host (`optchat-chief host`) and the acpmux it starts are agents too: in a
/// DEV build that embeds "cmux Files (dev)" they run under it, so their Files and Folders checks
/// are the helper's, shared by every DEV build (docs/cmux-files-host.md).
struct HomeBrainHostFilesHostTests {
    private static func host(filesHost: FilesHost?) -> HomeBrainHost {
        var host = HomeBrainHost(executable: URL(fileURLWithPath: "/App/cmux DEV one.app/Contents/Resources/bin/optchat-chief"),
                                 muxHome: URL(fileURLWithPath: "/Home/mux", isDirectory: true),
                                 daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock", acpmux: nil)
        host.filesHost = filesHost
        return host
    }

    @Test func aDevBuildRunsTheBrainHostUnderCmuxFiles() throws {
        let files = try #require(FilesHost(bundleURL: URL(fileURLWithPath: "/App/cmux DEV one.app", isDirectory: true),
                                           bundleIdentifier: "com.cmuxterm.app.debug.one", environment: [:],
                                           isDebugBuild: true, isExecutable: { _ in true }))
        let plain = Self.host(filesHost: nil).arguments
        let hosted = Self.host(filesHost: files).arguments
        let chief = "/App/cmux DEV one.app/Contents/Resources/bin/optchat-chief"

        #expect(Array(plain.dropFirst(2).prefix(2)) == ["mux-host-launch", chief])
        #expect(Array(hosted.dropFirst(2).prefix(5)) == ["mux-host-launch", files.executable.path, "run", "--", chief])
        #expect(Array(hosted.dropFirst(7)) == Array(plain.dropFirst(4)), "the host's own arguments are unchanged")
        #expect(hosted.prefix(2) == plain.prefix(2), "the same launch shell, so $! is still the pid Home watches")
    }

    /// A Release compile resolves no helper, so the brain host's argv is exactly as before.
    @Test func withoutTheHelperTheArgvIsUnchanged() {
        let arguments = Self.host(filesHost: nil).arguments
        #expect(Array(arguments.dropFirst(2)) == ["mux-host-launch", "/App/cmux DEV one.app/Contents/Resources/bin/optchat-chief",
                                                  "host", "--daemon-socket", "/tmp/d.sock", "--mux-home", "/Home/mux"])
    }
}
