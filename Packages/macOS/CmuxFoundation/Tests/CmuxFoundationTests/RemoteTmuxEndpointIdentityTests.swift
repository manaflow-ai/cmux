import Testing
@testable import CmuxFoundation

/// The endpoint identity hash keys the shared ssh master and every per-endpoint table, so
/// these pin the fingerprint that shipped and check that each component separates endpoints.
@Suite("Remote tmux endpoint identity")
struct RemoteTmuxEndpointIdentityTests {
    private func hash(_ fingerprint: String) -> String {
        RemoteTmuxEndpointIdentity.fnv1a64Hex(fingerprint)
    }

    /// FNV-1a/64 reference values, as 16 lowercase hex digits.
    @Test func fnv1a64MatchesTheReferenceVectors() {
        #expect(RemoteTmuxEndpointIdentity.fnv1a64Hex("") == "cbf29ce484222325")
        #expect(RemoteTmuxEndpointIdentity.fnv1a64Hex("a") == "af63dc4c8601ec8c")
        #expect(RemoteTmuxEndpointIdentity.fnv1a64Hex("foobar") == "85944171f73967e8")
    }

    /// A plain ssh host on the default server keeps the fingerprint that shipped before
    /// transports and socket names existed: destination, port, identity file, unit-separated.
    @Test func aPlainHostKeepsTheOriginalFingerprint() {
        #expect(RemoteTmuxEndpointIdentity(destination: "dev@host").connectionHash
            == hash("dev@host\u{1f}\u{1f}"))
        #expect(RemoteTmuxEndpointIdentity(destination: "dev@host", port: 2222, identityFile: "/keys/id").connectionHash
            == hash("dev@host\u{1f}2222\u{1f}/keys/id"))
    }

    /// A non-ssh transport appends its name and resolved port.
    @Test func aTransportAppendsItsNameAndResolvedPort() {
        let identity = RemoteTmuxEndpointIdentity(
            destination: "dev@host", transport: .init(name: "et", resolvedPort: 2022))

        #expect(identity.connectionHash == hash("dev@host\u{1f}\u{1f}\u{1f}et\u{1f}2022"))
    }

    /// A socket name appends after the transport, so both orders of setting them agree.
    @Test func aSocketNameAppendsAfterTheTransport() {
        #expect(RemoteTmuxEndpointIdentity(destination: "dev@host", socketName: "alpha").connectionHash
            == hash("dev@host\u{1f}\u{1f}\u{1f}socket\u{1f}alpha"))
        #expect(RemoteTmuxEndpointIdentity(
            destination: "dev@host",
            transport: .init(name: "et", resolvedPort: 2022),
            socketName: "alpha"
        ).connectionHash == hash("dev@host\u{1f}\u{1f}\u{1f}et\u{1f}2022\u{1f}socket\u{1f}alpha"))
    }

    /// Every component separates endpoints: no two of these may share a master or a mirror.
    @Test func eachComponentSeparatesEndpoints() {
        let et = RemoteTmuxEndpointIdentity.Transport(name: "et", resolvedPort: 2022)
        let identities = [
            RemoteTmuxEndpointIdentity(destination: "dev@host"),
            RemoteTmuxEndpointIdentity(destination: "Dev@host"),
            RemoteTmuxEndpointIdentity(destination: "dev@host", port: 2222),
            RemoteTmuxEndpointIdentity(destination: "dev@host", identityFile: "/keys/id"),
            RemoteTmuxEndpointIdentity(destination: "dev@host", transport: et),
            RemoteTmuxEndpointIdentity(destination: "dev@host", transport: .init(name: "et", resolvedPort: 2023)),
            RemoteTmuxEndpointIdentity(destination: "dev@host", socketName: "alpha"),
            RemoteTmuxEndpointIdentity(destination: "dev@host", socketName: "beta"),
            RemoteTmuxEndpointIdentity(destination: "dev@host", transport: et, socketName: "alpha"),
        ]

        #expect(Set(identities.map(\.connectionHash)).count == identities.count)
    }

    /// The same identity hashes the same way twice.
    @Test func theHashIsDeterministic() {
        let identity = RemoteTmuxEndpointIdentity(destination: "dev@host", socketName: "alpha")

        #expect(identity.connectionHash == identity.connectionHash)
        #expect(identity.connectionHash.count == 16)
    }
}
