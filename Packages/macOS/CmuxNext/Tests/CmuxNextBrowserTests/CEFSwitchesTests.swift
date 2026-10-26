import Foundation
import Testing
@testable import CmuxNextBrowser

/// Bench builds replay recorded pages with Web Page Replay (p12-perf-process task 221): the browser
/// process takes `host-resolver-rules` and `ignore-certificate-errors-spki-list` from
/// `CMUX_NEXT_BENCH_CEF_SWITCHES`, for a development or bench bundle, and nothing else from it.
@Suite struct CEFSwitchesTests {
    /// The rules Web Page Replay's README passes: ports and commas inside the value.
    static let rules = "host-resolver-rules=MAP *:80 127.0.0.1:8080,MAP *:443 127.0.0.1:8081,EXCLUDE localhost"
    static let spki = "ignore-certificate-errors-spki-list=PhrPvGIaAMmd29hj8BCZOq096yj7uMpRNHpn5PDxI6I="

    private func switches(bundle: String, bench: String, extra: [String: String] = [:]) -> [String] {
        CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: bundle,
                            environment: extra.merging(["CMUX_NEXT_BENCH_CEF_SWITCHES": bench]) { _, new in new }).arguments
    }

    @Test(arguments: ["com.cmuxterm.app.debug.bench-tag", "com.cmuxterm.app.next.dev"])
    func aBenchBundleTakesTheReplaySwitches(bundle: String) {
        let arguments = switches(bundle: bundle, bench: "--\(Self.rules)\n\(Self.spki)\n")
        #expect(arguments.contains(Self.rules))
        #expect(arguments.contains(Self.spki))
    }

    @Test func theBenchPathDropsEveryOtherSwitch() {
        let bench = [
            Self.rules,
            "remote-debugging-port=9222",
            "enable-features=BackForwardCache",
            "disable-gpu",
            "no-sandbox=1",
            "host-resolver-rules=",
            "ignore-certificate-errors-spki-list",
        ].joined(separator: "\n")
        #expect(CEFSwitches.benchSwitches(bench) == [Self.rules])
        let arguments = switches(bundle: "com.cmuxterm.app.debug.bench-tag", bench: bench)
        #expect(!arguments.contains("remote-debugging-port=9222"))
        #expect(!arguments.contains("enable-features=BackForwardCache"))
        #expect(!arguments.contains("disable-gpu"))
        #expect(!arguments.contains { $0.hasPrefix("no-sandbox") })
        #expect(arguments.filter { $0.hasPrefix("host-resolver-rules") } == [Self.rules])
    }

    /// A shipped bundle id never takes them, also not with the mock keychain variable a CI run sets.
    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.next"])
    func aShippedBundleIgnoresTheVariable(bundle: String) {
        let arguments = switches(bundle: bundle, bench: "\(Self.rules)\n\(Self.spki)", extra: ["CMUX_MOCK_KEYCHAIN": "1"])
        #expect(!arguments.contains { $0.hasPrefix("host-resolver-rules") || $0.hasPrefix("ignore-certificate-errors-spki-list") })
    }

    /// The bench list is newline-separated: the diagnostic list's colon would cut the rules apart.
    @Test func aColonInsideAValueStaysInTheSwitch() {
        #expect(CEFSwitches.benchSwitches(Self.rules) == [Self.rules])
        #expect(CEFSwitches.benchSwitches(nil).isEmpty)
        #expect(CEFSwitches.benchSwitches("\r\n\(Self.spki)\r\n") == [Self.spki])
    }
}
