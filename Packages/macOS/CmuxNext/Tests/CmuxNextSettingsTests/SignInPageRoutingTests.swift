@testable import CmuxNextSettings
import Foundation
import Testing

/// `browser.openSignInPagesInCmux` (on by default): a sign-in or device-code page (GitHub's
/// device page, `gh auth login`, `aws sso login`, a Codex or OpenCode device code, an OAuth
/// authorize page) opens in a cmux browser tab even when the link settings send other links to
/// the default browser. `browser.urlsToAlwaysOpenExternally` and a `terminal.linkOpener` rule
/// still win; the setting off leaves sign-in pages to the link settings like any link.
@Suite struct SignInPageRoutingTests {
    static func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

    static func routing(_ json: String) throws -> LinkRouting {
        let (routing, diagnostics) = LinkRouting.parse(try JSONValue.parse(Data(json.utf8)))
        #expect(diagnostics.isEmpty)
        return routing
    }

    @Test(arguments: [
        "https://example.com/device?code=ABCD-1234",
        "https://github.com/login/device",
        "https://github.com/login/oauth/authorize?client_id=x&state=y",
        "https://auth.openai.com/codex/device",
        "https://auth.openai.com/oauth/authorize?client_id=x",
        "https://console.opencode.ai/auth/device?code=WXYZ-0000",
        "https://claude.ai/oauth/authorize?code=true&client_id=x",
        "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
        "https://signin.aws.amazon.com/oauth?state=x",
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=x",
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        "https://microsoft.com/devicelogin",
        "https://www.google.com/device",
        "https://app.example.com/login?next=/",
        "https://example.com/sign-in",
        "https://x.awsapps.com/start/#/device?user_code=ABCD-EFGH",
    ])
    func signInPagesAreRecognized(text: String) throws {
        #expect(SignInPage(url: try Self.url(text)) != nil, "\(text)")
    }

    @Test(arguments: [
        "https://example.com/",
        "https://github.com/manaflow-ai/cmux/pull/1",
        "https://github.com/manaflow-ai/cmux/blob/main/auth.rs",
        "https://news.ycombinator.com/item?id=1",
        "https://docs.example.com/guides/devices",
        "https://github.com/golang/oauth2",
        "https://pkg.go.dev/golang.org/x/oauth2",
        "https://github.com/o/r/tree/main/src/auth",
        "https://supabase.com/docs/guides/auth",
        "https://developer.android.com/studio/run/device",
        "https://login.gov/help/",
        "file:///tmp/login",
        "mailto:login@example.com",
    ])
    func otherPagesAreNot(text: String) throws {
        #expect(SignInPage(url: try Self.url(text)) == nil, "\(text)")
    }

    @Test func onByDefault() throws {
        let routing = try Self.routing("{}")
        #expect(routing.signInPagesInCmux)
        #expect(routing.target(for: try Self.url("https://example.com/device?code=ABCD-1234")) == .cmuxBrowser)
    }

    /// Links off: other links go to the default browser, sign-in pages still open in cmux.
    @Test func signInPagesOpenInCmuxWhenLinksGoToTheDefaultBrowser() throws {
        let routing = try Self.routing(#"{"browser": {"openLinksInCmuxBrowser": false}}"#)
        #expect(routing.target(for: try Self.url("https://example.com/device?code=ABCD-1234")) == .cmuxBrowser)
        #expect(routing.target(for: try Self.url("https://github.com/login/device")) == .cmuxBrowser)
        #expect(routing.target(for: try Self.url("https://example.com/article")) == .system)
    }

    /// A host allowlist that misses the sign-in host does not send the sign-in page out.
    @Test func hostAllowlistDoesNotSendSignInPagesOut() throws {
        let routing = try Self.routing(#"{"browser": {"hostsToOpenInEmbeddedBrowser": ["localhost"]}}"#)
        #expect(routing.target(for: try Self.url("https://github.com/login/device")) == .cmuxBrowser)
        #expect(routing.target(for: try Self.url("https://github.com/manaflow-ai")) == .system)
    }

    /// An always-external rule is the person's explicit choice and still wins.
    @Test func alwaysExternalStillWins() throws {
        let routing = try Self.routing(#"{"browser": {"urlsToAlwaysOpenExternally": ["github.com/login"]}}"#)
        #expect(routing.target(for: try Self.url("https://github.com/login/device")) == .system)
    }

    /// Off: a sign-in page follows the link settings like any link.
    @Test func offLeavesSignInPagesToTheLinkSettings() throws {
        let routing = try Self.routing(#"{"browser": {"openSignInPagesInCmux": false, "openLinksInCmuxBrowser": false}}"#)
        #expect(!routing.signInPagesInCmux)
        #expect(routing.target(for: try Self.url("https://github.com/login/device")) == .system)
        let linksOn = try Self.routing(#"{"browser": {"openSignInPagesInCmux": false}}"#)
        #expect(linksOn.target(for: try Self.url("https://github.com/login/device")) == .cmuxBrowser)
    }

    /// The cmux browser off wins over everything.
    @Test func browserOffSendsEverythingOut() throws {
        let routing = try Self.routing(#"{"browser": {"enabled": false}}"#)
        #expect(routing.target(for: try Self.url("https://github.com/login/device")) == .system)
    }

    @Test func aNonBoolValueIsDiagnosed() throws {
        let (routing, diagnostics) = LinkRouting.parse(try JSONValue.parse(Data(#"{"browser": {"openSignInPagesInCmux": "yes"}}"#.utf8)))
        #expect(routing.signInPagesInCmux)
        #expect(diagnostics.map(\.path) == ["browser.openSignInPagesInCmux"])
    }

    /// `terminal.linkOpener`: with no rule matching, a program's sign-in page opens in cmux
    /// whatever the default target; a rule still wins; other links keep the default.
    @Test func programSignInPagesOpenInCmuxOverTheDefaultTarget() throws {
        let opener = TerminalLinkOpener(defaultTarget: .app("Helium", profile: nil),
                                        rules: [try #require(TerminalLinkOpenerRule("caller:aws -> chrome@Work"))])
        let routing = try Self.routing("{}")
        let device = try Self.url("https://example.com/device?code=ABCD-1234")
        #expect(opener.decide(device, callers: ["gh", "zsh"], routing: routing) == .init(target: .cmux, rule: nil))
        #expect(opener.decide(device, callers: ["aws"], routing: routing) == .init(target: .app("Google Chrome", profile: "Work"), rule: 0))
        #expect(opener.decide(try Self.url("https://example.com/article"), callers: ["gh"], routing: routing) ==
            .init(target: .app("Helium", profile: nil), rule: nil))
        let off = try Self.routing(#"{"browser": {"openSignInPagesInCmux": false}}"#)
        #expect(opener.decide(device, callers: ["gh"], routing: off) == .init(target: .app("Helium", profile: nil), rule: nil))
    }
}
