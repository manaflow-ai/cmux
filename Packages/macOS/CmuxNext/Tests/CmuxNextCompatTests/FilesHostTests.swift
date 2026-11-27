@testable import CmuxNextCompat
import Foundation
import Testing

/// Which builds run their daemons under "cmux Files (dev)" (docs/cmux-files-host.md).
struct FilesHostTests {
    private static let app = URL(fileURLWithPath: "/Applications/cmux DEV one.app", isDirectory: true)
    private static let embedded = "/Applications/cmux DEV one.app/" + FilesHost.embeddedExecutable

    private static func host(_ identifier: String?, environment: [String: String] = [:],
                             embedded: Bool = true, isDebugBuild: Bool = true) -> FilesHost? {
        FilesHost(bundleURL: app, bundleIdentifier: identifier, environment: environment,
                  isDebugBuild: isDebugBuild, isExecutable: { embedded && $0 == Self.embedded })
    }

    @Test func aDevBuildThatEmbedsTheHelperUsesIt() throws {
        for identifier in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.files-tcc",
                           "com.cmuxterm.app.debug.next"] {
            let host = try #require(Self.host(identifier), "\(identifier)")
            #expect(host.executable.path == Self.embedded)
        }
    }

    @Test func releaseChannelsNeverUseItEvenWithACopyInside() {
        for identifier in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                           "com.cmuxterm.app.rc", "com.cmuxterm.app.staging", "com.cmuxterm.app.staging.one",
                           "com.cmuxterm.app.debugger", "com.cmuxterm.cua", nil] {
            #expect(Self.host(identifier) == nil, "\(identifier ?? "nil")")
        }
    }

    /// Production safety (docs/cmux-files-host.md, "Production"): a Release-configuration compile
    /// (stable, NIGHTLY, RC, the NEXT DEV daily `com.cmuxterm.app.debug.next`, `--release` tags)
    /// never uses the helper, whatever its bundle id and even with a copy inside, and never
    /// looks at the disk for it.
    @Test func aReleaseCompileNeverUsesOrLooksForIt() {
        for identifier in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next", "com.cmuxterm.app.debug.files-tcc",
                           "com.cmuxterm.app", "com.cmuxterm.app.nightly"] {
            var looked = false
            let host = FilesHost(bundleURL: Self.app, bundleIdentifier: identifier, environment: [:],
                                 isDebugBuild: false, isExecutable: { _ in looked = true; return true })
            #expect(host == nil, "\(identifier)")
            #expect(!looked, "\(identifier)")
        }
    }

    /// The test bundle is a Debug compile, so the default reads `#if DEBUG`.
    @Test func theDefaultFollowsTheCompile() {
        #if DEBUG
        #expect(FilesHost.isDebugBuild)
        #else
        #expect(!FilesHost.isDebugBuild)
        #endif
    }

    @Test func aBuildWithoutTheHelperOrSwitchedOffRunsAsBefore() {
        #expect(Self.host("com.cmuxterm.app.debug.one", embedded: false) == nil)
        #expect(Self.host("com.cmuxterm.app.debug.one", environment: [FilesHost.switchKey: "0"]) == nil)
        #expect(Self.host("com.cmuxterm.app.debug.one", environment: [FilesHost.switchKey: "1"]) != nil)
    }

    @Test func theDaemonsRunUnderTheHelper() throws {
        let host = try #require(Self.host("com.cmuxterm.app.debug.one"))
        #expect(host.ownerEnvironment == ["CMUX_TUI_OWNER_LAUNCHER": Self.embedded])
        #expect(host.arguments(running: "/App/bin/acpmux") == [Self.embedded, "run", "--", "/App/bin/acpmux"])
    }
}
