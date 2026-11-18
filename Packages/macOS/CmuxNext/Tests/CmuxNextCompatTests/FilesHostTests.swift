@testable import CmuxNextCompat
import Foundation
import Testing

/// Which builds run their daemons under "cmux Files (dev)" (docs/cmux-files-host.md).
struct FilesHostTests {
    private static let app = URL(fileURLWithPath: "/Applications/cmux DEV one.app", isDirectory: true)
    private static let embedded = "/Applications/cmux DEV one.app/" + FilesHost.embeddedExecutable

    private static func host(_ identifier: String?, environment: [String: String] = [:],
                             embedded: Bool = true) -> FilesHost? {
        FilesHost(bundleURL: app, bundleIdentifier: identifier, environment: environment,
                  isExecutable: { embedded && $0 == Self.embedded })
    }

    @Test func aDevBuildThatEmbedsTheHelperUsesIt() throws {
        for identifier in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.files-tcc",
                           "com.cmuxterm.app.debug.next", "com.cmuxterm.app.staging.one"] {
            let host = try #require(Self.host(identifier), "\(identifier)")
            #expect(host.executable.path == Self.embedded)
        }
    }

    @Test func releaseChannelsNeverUseItEvenWithACopyInside() {
        for identifier in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                           "com.cmuxterm.app.rc", "com.cmuxterm.app.debugger", "com.cmuxterm.cua", nil] {
            #expect(Self.host(identifier) == nil, "\(identifier ?? "nil")")
        }
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
