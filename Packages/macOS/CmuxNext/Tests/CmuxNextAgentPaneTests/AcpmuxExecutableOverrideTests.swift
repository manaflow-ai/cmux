#if DEBUG
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// DEBUG's `CMUX_NEXT_ACPMUX_BIN`: which acpmux a running DEV build uses, and when a daemon of
/// another binary is restarted so the server peer check accepts the new one.
struct AcpmuxExecutableOverrideTests {
    private static let key = AcpmuxEnvironment.executableOverrideKey

    private static func decide(_ value: String?, links: [String: String] = [:],
                               executables: Set<String> = []) -> AcpmuxEnvironment.ExecutableOverride {
        AcpmuxEnvironment.executableOverride(environment: value.map { [key: $0] } ?? ["PATH": "/usr/bin"],
                                             resolveSymlinks: { links[$0] ?? $0 },
                                             isRegularExecutable: { executables.contains($0) })
    }

    @Test func unsetOrEmptyKeepsTheSearch() {
        #expect(Self.decide(nil) == .unset)
        #expect(Self.decide("") == .unset)
    }

    @Test func anAbsoluteExecutableWins() {
        let path = "/Users/dev/cmux-tui/target/debug/acpmux"
        #expect(Self.decide(path, executables: [path]) == .use(URL(fileURLWithPath: path)))
    }

    @Test func aSymlinkResolvesToItsTarget() {
        let link = "/Users/dev/.local/bin/acpmux-dev"
        let target = "/Users/dev/cmux-tui/target/debug/acpmux"
        #expect(Self.decide(link, links: [link: target], executables: [target]) == .use(URL(fileURLWithPath: target)))
        // The target is what must be executable, not the link.
        guard case .rejected = Self.decide(link, links: [link: target], executables: [link]) else {
            Issue.record("a link to a non-executable target was accepted"); return
        }
    }

    @Test func aRelativePathIsRejected() {
        for value in ["target/debug/acpmux", "./acpmux", "~/bin/acpmux"] {
            guard case .rejected(let why) = Self.decide(value, executables: [value]) else {
                Issue.record("\(value) was accepted"); continue
            }
            #expect(why.contains("absolute"))
        }
    }

    @Test func aMissingOrNonExecutablePathIsRejected() {
        guard case .rejected = Self.decide("/nowhere/acpmux") else {
            Issue.record("a missing path was accepted"); return
        }
    }

    @Test func theRealProbeRejectsDirectoriesAndPlainFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-override-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("plain")
        let tool = folder.appendingPathComponent("acpmux")
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        // A directory is "executable" (searchable) but not a regular file.
        #expect(!AcpmuxEnvironment.isRegularExecutableFile(folder.path))
        #expect(!AcpmuxEnvironment.isRegularExecutableFile(plain.path))
        #expect(AcpmuxEnvironment.isRegularExecutableFile(tool.path))
    }

    /// Through the test seam (the public resolve passes `debugExecutableOverride`): the override
    /// wins over a bundled binary, and nil leaves the usual search.
    @Test func resolvePrefersTheOverrideOverTheBundle() throws {
        let bin = URL(fileURLWithPath: "/Applications/cmux DEV.app/Contents/Resources/bin", isDirectory: true)
        let override = URL(fileURLWithPath: "/Users/dev/cmux-tui/target/debug/acpmux")
        func resolve(_ executableOverride: URL?) throws -> AcpmuxEnvironment {
            try #require(AcpmuxEnvironment.resolve(build: BuildIdentity(bundleID: "com.cmuxterm.app.debug.dev", bundledTag: "dev"), bundledBinDirectory: bin, environment: ["PATH": "/usr/bin"],
                                                   userHome: URL(fileURLWithPath: "/Users/dev", isDirectory: true), uid: 501,
                                                   isExecutable: { $0 == bin.appendingPathComponent("acpmux").path },
                                                   executableOverride: executableOverride))
        }
        let overridden = try resolve(override)
        #expect(overridden.executable == override)
        let searched = try resolve(nil)
        #expect(searched.executable == bin.appendingPathComponent("acpmux"))
        // Only the executable differs: home, socket and arguments stay the tag's.
        #expect(overridden.home == searched.home && overridden.socketPath == searched.socketPath)
        #expect(overridden.daemonArguments == searched.daemonArguments)
    }

    @Test func aSwapRestartsADaemonOfAnotherBinary() {
        let override = URL(fileURLWithPath: "/Users/dev/cmux-tui/target/debug/acpmux")
        let bundled = "/Applications/cmux DEV.app/Contents/Resources/bin/acpmux"
        #expect(AcpmuxVersionHandoff.swapsOverride(runningPath: bundled, override: override, executable: override))
        #expect(!AcpmuxVersionHandoff.swapsOverride(runningPath: override.path, override: override, executable: override))
        // Unknown running path: nothing to compare, keep the existing rules.
        #expect(!AcpmuxVersionHandoff.swapsOverride(runningPath: nil, override: override, executable: override))
        // No override, or an environment that does not run it: the existing rules alone decide.
        let other = URL(fileURLWithPath: bundled)
        #expect(!AcpmuxVersionHandoff.swapsOverride(runningPath: override.path, override: nil, executable: other))
        #expect(!AcpmuxVersionHandoff.swapsOverride(runningPath: override.path, override: override, executable: other))
    }

    @Test func aSwapRestartsADaemonThatKeepsItsChats() {
        // The swap goes through `decide(replaced:)`, same as a replaced bundle: a daemon with agent
        // hosts, or with its chats on disk, restarts; only a memory store without agent hosts keeps
        // running (its chats would be lost).
        #expect(AcpmuxVersionHandoff.decide("a", "a", true, chatsOnDisk: false, replaced: true) == .restart)
        #expect(AcpmuxVersionHandoff.decide("a", "a", false, chatsOnDisk: true, replaced: true) == .restart)
        #expect(AcpmuxVersionHandoff.decide("a", "a", false, chatsOnDisk: false, replaced: true) != .restart)
    }
}
#endif
