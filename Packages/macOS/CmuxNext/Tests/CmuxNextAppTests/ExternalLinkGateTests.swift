import AppKit
import CmuxNextOnboarding
import Foundation
import Testing

/// An `ssh://` link from another app (any web page can open one) asks before anything runs,
/// unless it names a host this Mac already knows: an acpmux peer, a saved SSH machine, or a host
/// the person chose "Always allow this host" for. Each case drives `ExternalLinkGate` with the
/// route `ExternalOpenRouter` makes of the link and records what the gate asked and ran.
@MainActor @Suite struct ExternalLinkGateTests {
    /// What the gate did, in order: `ask <display>`, `run`, `remember <key>`.
    final class Probe {
        var events: [String] = []
        var allowed: [String]
        init(allowed: [String]) { self.allowed = allowed }
    }

    func gate(_ probe: Probe, known: [String] = [], answer: SSHLinkAnswer = .cancel) -> ExternalLinkGate {
        ExternalLinkGate(knownHosts: { known }, allowedHosts: { probe.allowed },
                         rememberHost: { key in probe.events.append("remember \(key)"); probe.allowed.append(key) },
                         askSSH: { target, _ in probe.events.append("ask \(target.display)"); return answer })
    }

    func target(_ link: String) throws -> SSHLinkTarget {
        let url = try #require(URL(string: link))
        guard case .ssh(let target) = ExternalOpenRouter().route(url) else {
            Issue.record("\(link) did not route to an ssh confirmation: \(ExternalOpenRouter().route(url))")
            throw CancellationError()
        }
        return target
    }

    func open(_ link: String, _ gate: ExternalLinkGate, _ probe: Probe, opens: Bool = true) async throws {
        try await gate.openSSH(target(link)) {
            probe.events.append(opens ? "run" : "pane gone")
            return opens
        }
    }

    @Test func anUnknownHostAsksBeforeAnythingRuns() async throws {
        let probe = Probe(allowed: [])
        try await open("ssh://leo@build.example.com:2222", gate(probe, answer: .connect(always: false)), probe)
        #expect(probe.events == ["ask leo@build.example.com:2222", "run"])
    }

    @Test func cancelRunsNothing() async throws {
        let probe = Probe(allowed: [])
        try await open("ssh://attacker.example", gate(probe, answer: .cancel), probe)
        #expect(probe.events == ["ask attacker.example"])
    }

    @Test func aKnownPeerOrSavedMachineDoesNotAsk() async throws {
        let probe = Probe(allowed: [])
        let gate = gate(probe, known: ["cosmic-gray", "Build.Example.com"])
        try await open("ssh://cosmic-gray", gate, probe)
        try await open("ssh://root@BUILD.example.COM:22", gate, probe)
        #expect(probe.events == ["run", "run"])
    }

    @Test func anAlwaysAllowedHostDoesNotAsk() async throws {
        let probe = Probe(allowed: ["Lab.Example.com", "[fe80::1]"])
        let gate = gate(probe)
        try await open("ssh://lab.example.com", gate, probe)
        try await open("ssh://leo@[FE80::1]:2200", gate, probe)
        #expect(probe.events == ["run", "run"])
    }

    @Test func alwaysAllowRemembersTheHostAndTheNextLinkDoesNotAsk() async throws {
        let probe = Probe(allowed: [])
        let gate = gate(probe, answer: .connect(always: true))
        try await open("ssh://root@New.Example.com:2222", gate, probe)
        try await open("ssh://new.example.com", gate, probe)
        #expect(probe.events == ["ask root@New.Example.com:2222", "run", "remember new.example.com", "run"])
    }

    /// Connect in a window whose pane closed while the question was up opens nothing and
    /// remembers nothing, whatever "Always allow" said.
    @Test func aClosedPaneRemembersNothing() async throws {
        let probe = Probe(allowed: [])
        try await open("ssh://gone.example", gate(probe, answer: .connect(always: true)), probe, opens: false)
        #expect(probe.events == ["ask gone.example", "pane gone"])
        #expect(probe.allowed.isEmpty)
    }

    /// Trust is per host, compared without case and nothing else: a trailing dot, a longer name
    /// or a look-alike is another host to ssh, so it asks.
    @Test func onlyTheSameHostSkipsTheQuestion() async throws {
        let probe = Probe(allowed: ["example.com"])
        let gate = gate(probe)
        for link in ["ssh://example.com.", "ssh://example.com.evil.test", "ssh://evil-example.com", "ssh://example%2Ecom.evil.test"] {
            try await open(link, gate, probe)
        }
        #expect(probe.events.allSatisfy { $0.hasPrefix("ask ") } && probe.events.count == 4, "\(probe.events)")
    }

    @Test func peerHostsComeFromThePeerURLs() {
        #expect(ExternalLinkGate.peerHosts(["ssh://cosmic-gray", "ssh://leo@build.example.com:2222", "ssh://[fe80::2]:22", "not a url"])
            == ["cosmic-gray", "build.example.com", "fe80::2"])
    }

    /// The link carries only where to connect: an option-like host or login, a non-ASCII letter
    /// (a look-alike of a trusted host's) or a shell word never routes to a terminal. (URL itself
    /// maps the Kelvin sign to `k`, so ssh would connect to the ASCII host the dialog names.)
    @Test func aCraftedLinkNeverRoutes() throws {
        for link in ["ssh://-oProxyCommand=evil", "ssh://-l@host", "ssh://h%C3%B6st.example", "ssh://%D0%B0pple.example",
                     "ssh://host;rm%20-rf", "ssh://host:0", "ssh://us%27er@host",
                     // Only [user@]host[:port]: no password, path, query, fragment or unread port.
                     "ssh://leo:secret@host", "ssh://host/path", "ssh://host?x=1", "ssh://host#frag", "ssh://host:", "ssh://leo@[::1]:"] {
            let url = try #require(URL(string: link))
            #expect(ExternalOpenRouter().route(url) == .unsupported, "\(link)")
        }
    }

    @Test func theQuestionNamesTheTargetAsParsedAndTheCommandItRuns() throws {
        let v6 = try target("ssh://leo@[::1]:2222")
        #expect(v6.display == "leo@[::1]:2222")
        #expect(v6.command == "ssh -p 2222 -- 'leo@[::1]'")
        #expect(try target("ssh://build.example.com").command == "ssh -- 'build.example.com'")
    }

    @Test func anIPv6ZoneKeepsItsSpellingInTheTrustKey() {
        #expect(SSHLinkTarget.trustKey("[FE80::1%en0]") == "fe80::1%en0")
        #expect(SSHLinkTarget.trustKey("FE80::1%EN0") == "fe80::1%EN0")
        #expect(SSHLinkTarget.trustKey("Lab.Example.COM") == "lab.example.com")
    }

    @Test func aWindowThatClosedBeforeTheQuestionAnswersCancel() async {
        let closed = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        #expect(!closed.isVisible)
        #expect(await ExternalLinkGate.ask(SSHLinkTarget(user: nil, host: "build.example.com", port: nil), in: closed) == .cancel)
    }
}
