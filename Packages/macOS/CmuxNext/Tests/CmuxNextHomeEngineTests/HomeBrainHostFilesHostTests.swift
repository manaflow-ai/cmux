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

    /// `resolve` is where the app's brain host gets the helper: what it resolves reaches the argv,
    /// and a build that resolves none (every shipped build) launches exactly as before.
    @Test func resolveRunsTheHostUnderWhatTheBuildResolves() throws {
        let home = ChiefHome(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), isolated: true)
        let environment = ["CMUX_NEXT_MUX_HOST": "/bin/sh"]
        let files = try #require(FilesHost(bundleURL: URL(fileURLWithPath: "/App/cmux DEV one.app", isDirectory: true),
                                           bundleIdentifier: "com.cmuxterm.app.debug.one", environment: [:],
                                           isDebugBuild: true, isExecutable: { _ in true }))
        var asked: [[String: String]] = []
        let hosted = try #require(HomeBrainHost.resolve(daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock", home: home,
                                                        environment: environment, bundledBinDirectory: nil, bundledChiefAllowed: false,
                                                        filesHost: { asked.append($0); return files }))
        #expect(asked == [environment], "the build's environment decides, so CMUX_NEXT_FILES_HOST=0 reaches it")
        #expect(Array(hosted.arguments.dropFirst(3).prefix(4)) == [files.executable.path, "run", "--", "/bin/sh"])

        let plain = try #require(HomeBrainHost.resolve(daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock", home: home,
                                                       environment: environment, bundledBinDirectory: nil, bundledChiefAllowed: false,
                                                       filesHost: { _ in nil }))
        #expect(Array(plain.arguments.dropFirst(3).prefix(2)) == ["/bin/sh", "host"])
    }

    /// A Release compile resolves no helper, so the brain host's argv is exactly as before.
    @Test func withoutTheHelperTheArgvIsUnchanged() {
        let arguments = Self.host(filesHost: nil).arguments
        #expect(Array(arguments.dropFirst(2)) == ["mux-host-launch", "/App/cmux DEV one.app/Contents/Resources/bin/optchat-chief",
                                                  "host", "--daemon-socket", "/tmp/d.sock", "--mux-home", "/Home/mux"])
    }

    /// The pid the launch shell prints is the launcher's; a quit during the start stops it (it
    /// forwards SIGTERM). Only the helper's executable of this user's processes counts.
    @Test func theHelpersLauncherIsStoppable() {
        let files = "/App/cmux DEV one.app/" + FilesHost.embeddedExecutable
        #expect(ChiefHostStop.isFilesHostLauncher(path: files, processName: "cmux-files-host"))
        #expect(ChiefHostStop.isFilesHostLauncher(
            path: "/Users/me/Library/Application Support/cmux/files-host/app/0123/cmux Files (dev).app/Contents/MacOS/cmux-files-host",
            processName: "cmux-files-host"))
        #expect(!ChiefHostStop.isFilesHostLauncher(path: files, processName: nil), "another user's process")
        #expect(!ChiefHostStop.isFilesHostLauncher(path: nil, processName: "cmux-files-host"))
        #expect(!ChiefHostStop.isFilesHostLauncher(path: "/App/x.app/Contents/Resources/bin/cmux-tui", processName: "cmux-tui"))
        #expect(!ChiefHostStop.isFilesHostLauncher(getpid()), "this test process")
    }
}
