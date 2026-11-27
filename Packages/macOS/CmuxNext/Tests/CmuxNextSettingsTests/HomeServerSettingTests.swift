import CmuxNextSettings
import Foundation
import Testing

/// `home.server`: Home's messages go to cmux Cloud (`"hosted"`, the default) or to a self-hosted
/// server reached over Tailscale (`{"selfHosted": "http://mini.tail1234.ts.net:7320"}`),
/// in cmux.json and Settings (dm-group-chat-DESIGN.md 4.5).
struct HomeServerSettingTests {
    private func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["home": .object(["server": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    private func selfHosted(_ url: String) -> JSONValue { .object(["selfHosted": .string(url)]) }

    @Test func cmuxCloudByDefault() {
        let snapshot = parse(nil)
        #expect(snapshot.homeServer == .hosted)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func hostedNamesCmuxCloud() {
        let snapshot = parse(.string("hosted"))
        #expect(snapshot.homeServer == .hosted)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [
        ("http://mini.tail1234.ts.net:7320", "http://mini.tail1234.ts.net:7320"),
        ("http://mini.tail1234.ts.net:7320/", "http://mini.tail1234.ts.net:7320"),
        ("HTTPS://Mini.Tail1234.ts.net", "https://mini.tail1234.ts.net"),
        ("http://100.101.102.103:7320", "http://100.101.102.103:7320"),
    ])
    func aSelfHostedServerIsItsOrigin(input: String, origin: String) throws {
        let expected = try #require(URL(string: origin))
        let snapshot = parse(selfHosted(input))
        #expect(snapshot.homeServer == .selfHosted(expected))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [
        JSONValue.number(1),
        .string("selfHosted"),
        .bool(true),
        .object(["selfHosted": .string("ftp://mini.tail1234.ts.net")]),
        .object(["selfHosted": .string("http://mini.tail1234.ts.net/path")]),
        .object(["selfHosted": .string("http://mini.tail1234.ts.net?x=1")]),
        .object(["selfHosted": .string("http://user@mini.tail1234.ts.net")]),
        .object(["selfHosted": .string("not a url")]),
        .object(["selfHosted": .number(7320)]),
        .object(["other": .string("http://mini.tail1234.ts.net")]),
        .object(["selfHosted": .string("http://mini.tail1234.ts.net"), "extra": .string("x")]),
    ])
    func anythingElseIsCmuxCloudWithADiagnostic(value: JSONValue) {
        let snapshot = parse(value)
        #expect(snapshot.homeServer == .hosted)
        #expect(snapshot.diagnostics.contains { $0.path == "home.server" })
    }

    @Test func theSettingsRowIsAChoiceOrAServerAddress() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeServerSetting.configPath))
        #expect(row.id == HomeServerSetting.key)
        #expect(row.section == .home)
        #expect(row.defaultValue == .string("hosted"))
        #expect(String(describing: row.kind).hasPrefix("choiceOrURL"))
        #expect(String(describing: row.kind).contains("selfHosted"))
    }

    @Test func theRowAcceptsWhatTheParserApplies() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeServerSetting.configPath))
        #expect(row.accepts(.string("hosted")))
        #expect(row.accepts(selfHosted("http://mini.tail1234.ts.net:7320")))
        #expect(row.accepts(selfHosted("https://100.101.102.103/")))
        #expect(!row.accepts(.string("selfHosted")))
        #expect(!row.accepts(selfHosted("ftp://mini.tail1234.ts.net")))
        #expect(!row.accepts(selfHosted("http://mini.tail1234.ts.net/path")))
        #expect(!row.accepts(.object(["other": .string("http://mini.tail1234.ts.net")])))
        #expect(!row.accepts(.number(1)))
    }

    @Test func agentsMayNotMoveTheMessages() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeServerSetting.configPath))
        #expect(SettingsSchema.agentSettable(row) != true)
        #expect(SettingsSchema.agentRefusedKeys[HomeServerSetting.key] == .privacy)
    }

    @Test func theSettingsPageDrawsItInAccounts() throws {
        let accounts = try #require(SettingsPageLayout().categories().first { $0.spec.id == "accounts" })
        #expect(accounts.groups.contains { $0.rows.contains(HomeServerSetting.key) })
    }
}
