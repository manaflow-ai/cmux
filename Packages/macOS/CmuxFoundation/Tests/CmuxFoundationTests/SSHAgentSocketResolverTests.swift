import Testing
@testable import CmuxFoundation

@Suite("OpenSSH option parsing")
struct SSHAgentSocketResolverTests {
    /// Verifies that copying a literal agent never corrupts OpenSSH's inherited environment references.
    @Test("identity agent subprocess environments preserve OpenSSH references", arguments: [
        ([], "/tmp/inherited.sock" as String?),
        (["IdentityAgent="], "/tmp/inherited.sock"),
        (["IdentityAgent=\"\"", "IdentityAgent=/tmp/later.sock"], "/tmp/inherited.sock"),
        (["IdentityAgent=SSH_AUTH_SOCK"], "/tmp/inherited.sock"),
        (["IdentityAgent = \"SSH_AUTH_SOCK\"", "IdentityAgent=/tmp/later.sock"], "/tmp/inherited.sock"),
        (["IdentityAgent=$OTHER_AGENT"], "/tmp/inherited.sock"),
        (["IdentityAgent=${SSH_AUTH_SOCK}"], "/tmp/inherited.sock"),
        (["IdentityAgent=~/.ssh/agent"], "/tmp/inherited.sock"),
        (["IdentityAgent=/tmp/agent-%u"], "/tmp/inherited.sock"),
        (["IdentityAgent=/tmp/${USER}/agent"], "/tmp/inherited.sock"),
        (["IdentityAgent=none"], nil),
        (["IdentityAgent=NONE", "IdentityAgent=/tmp/later.sock"], nil),
        (["IdentityAgent=/tmp/configured.sock"], "/tmp/configured.sock"),
        (["identityagent = \"/tmp/agent socket\""], "/tmp/agent socket"),
        (["IdentityAgent=/tmp/first.sock", "IdentityAgent=/tmp/later.sock"], "/tmp/first.sock"),
    ])
    func identityAgentEnvironment(options: [String], expectedSocket: String?) {
        let inherited = ["SSH_AUTH_SOCK": "/tmp/inherited.sock", "OTHER_AGENT": "/tmp/other.sock", "PATH": "/usr/bin"]
        var expected = inherited
        expected["SSH_AUTH_SOCK"] = expectedSocket
        #expect(SSHAgentSocketResolver(environment: inherited).environmentForIdentityAgent(in: options) == expected)
    }

    /// Preserves an absent inherited socket instead of turning the environment token into a filename.
    @Test("identity agent environment token does not invent a missing socket")
    func identityAgentWithNoInheritedSocket() {
        #expect(SSHAgentSocketResolver(environment: [:])
            .environmentForIdentityAgent(in: ["IdentityAgent=SSH_AUTH_SOCK"]).isEmpty)
    }

    @Test("reads quoted values with whitespace around the separator")
    func readsOpenSSHOptionSpellings() {
        let resolver = SSHAgentSocketResolver(environment: [:])

        #expect(resolver.optionValue(
            named: "RequestTTY",
            in: ["RequestTTY = \"no\""]
        ) == "no")
        #expect(resolver.optionValue(
            named: "RequestTTY",
            in: ["RequestTTY= 'yes'"]
        ) == "yes")
        #expect(resolver.optionValue(
            named: "RequestTTY",
            in: ["RequestTTY \"false\""]
        ) == "false")
    }

    @Test(arguments: ["ForwardAgent=\"\"", "ForwardAgent=''"])
    func skipsEmptyQuotedValues(_ emptyOption: String) {
        let resolver = SSHAgentSocketResolver(environment: [:])

        #expect(resolver.optionValue(
            named: "ForwardAgent",
            in: [emptyOption, "ForwardAgent=yes"]
        ) == "yes")
    }

    @Test("forces Mosh management connections to stay non-PTY")
    func moshManagementOptionsDisableTTY() {
        let resolver = SSHAgentSocketResolver(environment: [:])
        let options = [
            "RequestTTY=yes",
            "ProxyJump=bastion",
            "RequestTTY=force",
        ]

        let expected = [
            "ProxyJump=bastion",
            "RequestTTY=no",
        ]
        #expect(resolver.nonInteractiveOptions(from: options) == expected)
        #expect(resolver.moshManagementOptions(from: options) == expected)
    }
}
