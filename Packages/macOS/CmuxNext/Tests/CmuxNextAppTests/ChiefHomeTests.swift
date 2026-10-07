import Foundation
import Testing
@testable import CmuxNextApp

/// One Chief per user account: every DEV tag, NIGHTLY and Release build opens
/// the same Chief home, so the Home transcript and the Chief's memory are the
/// same history whatever build Lawrence opens. On 2026-10-05 hmchief3 held
/// 11 messages and a 34-entry OptChat log while hmchief and hmchief4 each
/// showed their own one-message Chief, because each tag had its own mux home
/// and its own daemon conversation store.
@Suite struct ChiefHomeTests {
    static let user = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    static func resolve(tag: String?, _ environment: [String: String] = [:]) -> ChiefHome {
        ChiefHome.resolve(tag: tag, environment: environment, userHome: user)
    }

    @Test func everyTagOpensTheSameChiefHome() {
        let three = Self.resolve(tag: "hmchief3")
        let four = Self.resolve(tag: "hmchief4")
        let nightly = Self.resolve(tag: nil)
        #expect(three == four)
        #expect(three == nightly)
        #expect(three.root.path == "/Users/someone/.cmux/chief/default")
        #expect(!three.isolated)
    }

    @Test func theChiefHomeHoldsTheMemoryTheConversationOwnerAndTheAgents() {
        let home = Self.resolve(tag: "hmchief4")
        #expect(home.muxHome.path == "/Users/someone/.cmux/chief/default")
        #expect(home.daemonStateDirectory.path == "/Users/someone/.cmux/chief/default/tui")
        #expect(home.acpmuxHome.path == "/Users/someone/.cmux/chief/default/acpmux")
        // One daemon session per Chief home, never a tag's session.
        #expect(home.session.hasPrefix("cmux-chief-"))
        #expect(home.session == Self.resolve(tag: "hmchief").session)
    }

    @Test func anAccountGetsItsOwnChief() {
        let home = Self.resolve(tag: "hmchief4", ["CMUX_NEXT_CHIEF_ACCOUNT": "user 42/x"])
        #expect(home.root.path == "/Users/someone/.cmux/chief/user-42-x")
        #expect(home.session != Self.resolve(tag: "hmchief4").session)
    }

    @Test func agentPreflightsAndTestWindowsNeverTouchTheRealChief() {
        for environment in [["CMUX_NEXT_NO_ACTIVATE": "1"], ["CMUX_NEXT_CHIEF_ISOLATED": "1"],
                            ["CMUX_NEXT_TEST_WINDOW_FRAME": "0,0,800,600"], ["CMUX_NEXT_SHOWCASE": "1"]] {
            let home = Self.resolve(tag: "pf1", environment)
            #expect(home.isolated, "\(environment)")
            #expect(home.root.path == "/Users/someone/.cmux/chief/isolated/pf1", "\(environment)")
            #expect(home.session != Self.resolve(tag: "pf1").session, "\(environment)")
        }
        #expect(Self.resolve(tag: nil, ["CMUX_NEXT_NO_ACTIVATE": "1"]).root.path == "/Users/someone/.cmux/chief/isolated/untagged")
    }

    @Test func anExplicitHomeWinsAndTwoBuildsCanShareIt() {
        let a = Self.resolve(tag: "pfa", ["CMUX_NEXT_CHIEF_HOME": "/tmp/chief-pf", "CMUX_NEXT_NO_ACTIVATE": "1"])
        let b = Self.resolve(tag: "pfb", ["CMUX_NEXT_CHIEF_HOME": "/tmp/chief-pf"])
        #expect(a.root.path == "/tmp/chief-pf")
        #expect(a == b)
        // The old per-tag override keeps working for isolated tests.
        #expect(Self.resolve(tag: "x", ["CMUX_NEXT_MUX_HOME": "/tmp/old-mux"]).root.path == "/tmp/old-mux")
    }

    @Test func theSessionNameIsShortAndStable() {
        let home = Self.resolve(tag: nil)
        #expect(home.session == ChiefHome.sessionName(root: home.root))
        #expect(home.session.count == "cmux-chief-".count + 8)
        #expect(ChiefHome.sessionName(root: URL(fileURLWithPath: "/a")) != ChiefHome.sessionName(root: URL(fileURLWithPath: "/b")))
    }
}
