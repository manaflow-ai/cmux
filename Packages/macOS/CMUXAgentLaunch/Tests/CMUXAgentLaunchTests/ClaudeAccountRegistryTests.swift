import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeAccountRegistryTests {
    private let home = "/Users/u"

    private func registry(_ declarations: [ClaudeAccountDeclaration]) -> ClaudeAccountRegistry {
        ClaudeAccountRegistry(declarations: declarations, homeDirectory: home)
    }

    @Test func implicitDefaultComesFirst() {
        let r = registry([.init(name: "work", configDir: "~/.claude-work")])
        #expect(r.accounts.map(\.name) == ["default", "work"])
        #expect(r.accounts[0].configDirectory == nil)
        #expect(r.accounts[1].configDirectory == "/Users/u/.claude-work")
    }

    @Test func declaredDefaultKeepsUserNameAndOrder() {
        let r = registry([.init(name: "qa", configDir: "~/.claude-work"), .init(name: "ph", configDir: "~/.claude")])
        #expect(r.accounts.map(\.name) == ["qa", "ph"])
        #expect(r.account(named: "ph")?.isDefault == true)
    }

    @Test func normalizesEquivalentConfigDirSpellings() {
        let r = registry([.init(name: "work", configDir: "/Users/u/.claude-work/")])
        #expect(r.account(forEnvironment: ["CLAUDE_CONFIG_DIR": "~/.claude-work"]).name == "work")
        #expect(r.account(forEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude"]).isDefault)
        #expect(r.account(forEnvironment: ["CLAUDE_CONFIG_DIR": ""]).isDefault)
        #expect(r.account(forEnvironment: nil).isDefault)
    }

    @Test func unknownDirIsUnregistered() {
        let a = registry([]).account(forEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-old"])
        #expect(a.isRegistered == false)
        #expect(a.name == "old")
    }

    @Test func invalidAndDuplicateDeclarations() {
        let r = registry([
            .init(name: "bad name", configDir: "~/.x"), .init(name: "rel", configDir: "relative/dir"),
            .init(name: "a", configDir: "~/.one"), .init(name: "b", configDir: "~/.one"),
            .init(name: "a", configDir: "~/.two"),
        ])
        #expect(r.accounts.map(\.name) == ["default", "a"])
        #expect(r.account(named: "a")?.configDirectory == "/Users/u/.two")
    }

    @Test func reservedDefaultNameWithCustomDirIsDropped() {
        let r = registry([.init(name: "default", configDir: "~/.claude-work")])
        #expect(r.accounts.map(\.name) == ["default"])
        #expect(r.accounts[0].isDefault)
        let ok = registry([.init(name: "default", configDir: "~/.claude")])
        #expect(ok.accounts.map(\.name) == ["default"])
    }

    @Test func decodesAgentsClaudeAccountsAndIgnoresMalformed() {
        let json = #"{"agents":{"claudeAccounts":[{"name":"work","configDir":"~/.claude-work"}]}}"#
        #expect(ClaudeAccountRegistry.declarations(sanitizedConfigJSON: Data(json.utf8)) == [.init(name: "work", configDir: "~/.claude-work")])
        #expect(ClaudeAccountRegistry.declarations(sanitizedConfigJSON: Data("{".utf8)).isEmpty)
    }

    @Test func exhaustionKeyUsesHomeForDefault() {
        #expect(registry([]).accounts[0].exhaustionKey(homeDirectory: home) == "/Users/u/.claude")
        let w = registry([.init(name: "w", configDir: "~/.w")]).accounts[1]
        #expect(w.exhaustionKey(homeDirectory: home) == "/Users/u/.w")
    }

    @Test func projectConfigOverridesGlobalByName() throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("acct-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }
        let tmpHome = root + "/home"
        let project = root + "/project"
        try fm.createDirectory(atPath: tmpHome + "/.config/cmux", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: project + "/.cmux", withIntermediateDirectories: true)
        let global = #"{"agents":{"claudeAccounts":[{"name":"work","configDir":"~/.a"}]}}"#
        let local = #"{"agents":{"claudeAccounts":[{"name":"work","configDir":"~/.b"}]}}"#
        try global.write(toFile: tmpHome + "/.config/cmux/cmux.json", atomically: true, encoding: .utf8)
        try local.write(toFile: project + "/.cmux/cmux.json", atomically: true, encoding: .utf8)

        let r = ClaudeAccountRegistry.load(homeDirectory: tmpHome, workingDirectory: project, sanitize: { $0 })
        let standardizedHome = (tmpHome as NSString).standardizingPath
        #expect(r.account(named: "work")?.configDirectory == standardizedHome + "/.b")
    }

    /// Automatic switching runs unattended, so a project's `.cmux/cmux.json` can neither add an
    /// account to it nor point one of the user's accounts elsewhere.
    @Test func userLevelLoadIgnoresEveryProjectConfig() throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("acct-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }
        let tmpHome = root + "/home"
        try fm.createDirectory(atPath: tmpHome + "/.config/cmux", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmpHome + "/.cmux", withIntermediateDirectories: true)
        let user = #"{"agents":{"claudeAccounts":[{"name":"work","configDir":"~/.a"}]}}"#
        // A project config at the home root is what a pane anywhere under home finds first.
        let project = #"{"agents":{"claudeAccounts":[{"name":"work","configDir":"~/.evil"},{"name":"rogue","configDir":"/tmp/rogue"}]}}"#
        try user.write(toFile: tmpHome + "/.config/cmux/cmux.json", atomically: true, encoding: .utf8)
        try project.write(toFile: tmpHome + "/.cmux/cmux.json", atomically: true, encoding: .utf8)
        let standardizedHome = (tmpHome as NSString).standardizingPath

        let merged = ClaudeAccountRegistry.load(homeDirectory: tmpHome, workingDirectory: tmpHome, sanitize: { $0 })
        #expect(merged.account(named: "rogue") != nil)

        let userLevel = ClaudeAccountRegistry.loadUserLevel(homeDirectory: tmpHome, sanitize: { $0 })
        #expect(userLevel.accounts.map(\.name) == [ClaudeAccountRegistry.defaultAccountName, "work"])
        #expect(userLevel.account(named: "work")?.configDirectory == standardizedHome + "/.a")
    }
}
