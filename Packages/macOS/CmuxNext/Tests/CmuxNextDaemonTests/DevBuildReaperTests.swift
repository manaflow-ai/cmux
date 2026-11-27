@testable import CmuxNextDaemon
import Foundation
import Testing

/// Only a tagged DEV build starts the reaper that ends its helpers at exit (issue 55842).
struct DevBuildReaperTests {
    private static let bundle = URL(fileURLWithPath: "/Users/me/dev-builds/t/cmux DEV t.app")

    private static func reaper(_ id: String?, environment: [String: String] = [:], bundle: URL = bundle) -> DevBuildReaper? {
        DevBuildReaper(bundleURL: bundle, bundleIdentifier: id, environment: environment, isExecutable: { _ in true })
    }

    @Test func aTaggedDevBuildStartsIt() throws {
        let reaper = try #require(Self.reaper("com.cmuxterm.app.debug.55842-quit-reaps"))
        #expect(reaper.tag == "55842-quit-reaps")
        #expect(reaper.executable.path == "/Users/me/dev-builds/t/cmux DEV t.app/Contents/Resources/bin/cmux-tui")
    }

    @Test func shippedBuildsTheDailyAndAnOptOutKeepTheirHelpers() {
        for id in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next",
                   "com.cmuxterm.app.staging.t", "com.cmuxterm.app.debug."] {
            #expect(Self.reaper(id) == nil, "\(id)")
        }
        #expect(Self.reaper(nil) == nil)
        #expect(Self.reaper("com.cmuxterm.app.debug.t", environment: ["CMUX_DEV_KEEP_HELPERS": "1"]) == nil)
        #expect(Self.reaper("com.cmuxterm.app.debug.t", bundle: URL(fileURLWithPath: "/usr/local/bin")) == nil)
        #expect(DevBuildReaper(bundleURL: Self.bundle, bundleIdentifier: "com.cmuxterm.app.debug.t", environment: [:],
                               isExecutable: { _ in false }) == nil)
    }

    @Test func theShellBackgroundsTheReaperInItsOwnGroup() throws {
        let reaper = try #require(Self.reaper("com.cmuxterm.app.debug.t"))
        let arguments = reaper.arguments(appPID: 4242, log: "/tmp/r.log")
        #expect(arguments == ["-c", #"set -m; "$@" >>"$0" 2>&1 </dev/null &"#, "/tmp/r.log",
                              "/Users/me/dev-builds/t/cmux DEV t.app/Contents/Resources/bin/cmux-tui",
                              "__dev-reaper", "--app-pid", "4242", "--bundle", "/Users/me/dev-builds/t/cmux DEV t.app",
                              "--bundle-id", "com.cmuxterm.app.debug.t"])
    }
}
