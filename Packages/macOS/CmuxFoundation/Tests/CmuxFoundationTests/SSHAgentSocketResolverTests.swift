import Testing
@testable import CmuxFoundation

@Suite("OpenSSH option parsing")
struct SSHAgentSocketResolverTests {
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
}
