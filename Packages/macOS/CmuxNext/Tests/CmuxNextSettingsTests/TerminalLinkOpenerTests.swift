@testable import CmuxNextSettings
import Foundation
import Testing

/// `terminal.linkOpener`: where a URL a terminal program opens goes. The first matching rule
/// wins, else the default (cmux); a rule matches by caller process name and by URL pattern.
@Suite struct TerminalLinkOpenerTests {
    static func setting(_ json: String) throws -> (TerminalLinkOpener, [SettingsDiagnostic]) {
        TerminalLinkOpener.parse(try JSONValue.parse(Data(json.utf8)))
    }

    static func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

    @Test func unsetOpensInCmux() throws {
        let (setting, diagnostics) = try Self.setting("{}")
        #expect(diagnostics.isEmpty)
        #expect(setting.decide(try Self.url("https://signin.aws.amazon.com/x"), callers: ["aws"]) ==
            .init(target: .cmux, rule: nil))
    }

    @Test(arguments: [
        ("cmux", TerminalLinkOpenerTarget.cmux),
        ("system", .system),
        ("Chrome", .app("Google Chrome", profile: nil)),
        ("chrome@Profile 1", .app("Google Chrome", profile: "Profile 1")),
        ("safari", .app("Safari", profile: nil)),
        ("arc", .app("Arc", profile: nil)),
        ("firefox@work", .app("Firefox", profile: "work")),
        ("app:Zen", .app("Zen", profile: nil)),
        ("app:/Applications/Vivaldi.app@Default", .app("/Applications/Vivaldi.app", profile: "Default")),
        ("command:~/bin/pick-browser --verbose", .command("~/bin/pick-browser --verbose")),
    ])
    func targetsParse(text: String, target: TerminalLinkOpenerTarget) {
        #expect(TerminalLinkOpenerTarget(text) == target)
    }

    @Test(arguments: ["", "netscape", "app:", "command:", "app:@x"])
    func unknownTargetsAreRefused(text: String) {
        #expect(TerminalLinkOpenerTarget(text) == nil)
    }

    @Test func firstMatchingRuleWins() throws {
        let (setting, diagnostics) = try Self.setting("""
        {"terminal": {"linkOpener": {"default": "system", "rules": [
          "caller:aws -> chrome@Work",
          "caller:gh,git github.com/login -> safari",
          "re:^https://[^/]*\\\\.corp\\\\.example\\\\.com/ -> app:Arc",
          "caller:aws -> firefox",
          "* -> command:~/bin/pick"
        ]}}}
        """)
        #expect(diagnostics.isEmpty)
        #expect(setting.rules.count == 5)
        let aws = setting.decide(try Self.url("https://signin.aws.amazon.com/oauth"), callers: ["python3.12", "aws", "zsh"])
        #expect(aws == .init(target: .app("Google Chrome", profile: "Work"), rule: 0), "rule 3 also matches aws; rule 0 is first")
        let gh = setting.decide(try Self.url("https://github.com/login/device"), callers: ["GH"])
        #expect(gh == .init(target: .app("Safari", profile: nil), rule: 1))
        let ghElsewhere = setting.decide(try Self.url("https://github.com/cli/cli"), callers: ["gh"])
        #expect(ghElsewhere.rule == 4, "the URL pattern of rule 1 misses, so the catch-all decides")
        let corp = setting.decide(try Self.url("https://wiki.corp.example.com/a"), callers: ["node"])
        #expect(corp == .init(target: .app("Arc", profile: nil), rule: 2))
    }

    @Test func noRuleMatchesUsesTheDefault() throws {
        let (setting, _) = try Self.setting("""
        {"terminal": {"linkOpener": {"default": "safari", "rules": ["caller:gcloud -> chrome"]}}}
        """)
        #expect(setting.decide(try Self.url("https://accounts.google.com/o"), callers: ["npm"]) ==
            .init(target: .app("Safari", profile: nil), rule: nil))
        #expect(setting.decide(try Self.url("https://accounts.google.com/o"), callers: ["gcloud"]).rule == 0)
    }

    @Test func callerGlobsMatchWholeNames() throws {
        let rule = try #require(TerminalLinkOpenerRule("caller:python3* -> system"))
        let url = try Self.url("https://a.example/")
        #expect(rule.matches(url, callers: ["Python3.12"]))
        #expect(!rule.matches(url, callers: ["ipython"]))
        #expect(!rule.matches(url, callers: []))
    }

    @Test func badValuesAreReportedAndSkipped() throws {
        let (setting, diagnostics) = try Self.setting("""
        {"terminal": {"linkOpener": {"default": "netscape", "rules": ["no arrow", "caller:aws -> chrome", "x -> nowhere"]}}}
        """)
        #expect(setting.defaultTarget == .cmux)
        #expect(setting.rules.map(\.text) == ["caller:aws -> chrome"])
        #expect(diagnostics.map(\.path) == ["terminal.linkOpener.default", "terminal.linkOpener.rules", "terminal.linkOpener.rules"])
    }

    @Test func snapshotCarriesTheSetting() throws {
        let snapshot = CmuxConfigSnapshot.parse(try JSONValue.parse(Data("""
        {"terminal": {"linkOpener": {"default": "command:pick", "rules": ["caller:aws -> system"]}}}
        """.utf8)), validDensities: [], validMetrics: [])
        #expect(snapshot.terminalLinkOpener.defaultTarget == .command("pick"))
        #expect(snapshot.terminalLinkOpener.rules.count == 1)
    }

    @Test func profilesLaunchOnlyBrowsersThatTakeThem() throws {
        let url = try Self.url("https://a.example/")
        #expect(TerminalLinkOpenerTarget.app("Google Chrome", profile: "Profile 1").launch(for: url) ==
            TerminalLinkOpenerLaunch(app: "Google Chrome", arguments: ["--profile-directory=Profile 1", "https://a.example/"], newInstance: true))
        #expect(TerminalLinkOpenerTarget.app("Firefox", profile: "work").launch(for: url) ==
            TerminalLinkOpenerLaunch(app: "Firefox", arguments: ["-P", "work", "-new-tab", "https://a.example/"], newInstance: true))
        #expect(TerminalLinkOpenerTarget.app("Safari", profile: "x").launch(for: url) ==
            TerminalLinkOpenerLaunch(app: "Safari", arguments: [], newInstance: false))
        #expect(TerminalLinkOpenerTarget.app("Arc", profile: nil).launch(for: url) ==
            TerminalLinkOpenerLaunch(app: "Arc", arguments: [], newInstance: false))
        #expect(TerminalLinkOpenerTarget.cmux.launch(for: url) == nil)
    }
}
