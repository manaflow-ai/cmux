import CmuxNextActions
import Foundation
import Testing

/// `cmux://` links (the deep links contract): every route formats and parses
/// back to itself in the running build's scheme, nightly's forms still
/// parse, and nothing else is a link.
@Suite nonisolated struct DeepLinkTests {
    static let hex = "0123456789abcdef0123456789abcdef"
    static let workspace = "ws_" + hex
    static let pane = "pane_" + hex
    static let tab = "tab_" + hex
    static let machine = "machine_" + hex
    static let uuidA = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let uuidB = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let uuidC = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    static func url(_ text: String) -> URL { URL(string: text)! }

    static let routes: [(DeepLink, String)] = [
        (DeepLink(.workspace(workspace)), "cmux://workspace/\(workspace)"),
        (DeepLink(.pane(pane)), "cmux://pane/\(pane)"),
        (DeepLink(.tab(tab)), "cmux://tab/\(tab)"),
        (DeepLink(.session("sess-01.ab_c", turn: nil)), "cmux://session/sess-01.ab_c"),
        (DeepLink(.session("sess-1", turn: "turn-7")), "cmux://session/sess-1#turn-turn-7"),
        (DeepLink(.tab(tab), machine: machine), "cmux://tab/\(tab)?machine=\(machine)"),
        (DeepLink(.session("s1", turn: "t2"), machine: machine), "cmux://session/s1?machine=\(machine)#turn-t2"),
    ]

    @Test(arguments: DeepLinkTests.routes)
    func everyRouteFormatsAndParsesBack(link: DeepLink, text: String) throws {
        let url = try #require(link.url(scheme: "cmux"))
        #expect(url.absoluteString == text)
        #expect(DeepLink.parse(url, scheme: "cmux") == link)
    }

    @Test func theRunningBuildsSchemeIsTheOnlyOneParsed() throws {
        let link = DeepLink(.tab(Self.tab))
        for scheme in ["cmux", "cmux-dev", "cmux-dev-fix-abc-1", "cmux-nightly"] {
            let url = try #require(link.url(scheme: scheme))
            #expect(url.absoluteString == "\(scheme)://tab/\(Self.tab)")
            #expect(DeepLink.parse(url, scheme: scheme) == link, "\(scheme)")
            #expect(DeepLink.parse(url, scheme: scheme.uppercased()) == link, "schemes compare case-insensitively")
        }
        // Another build's link is not opened here.
        #expect(DeepLink.parse(Self.url("cmux-dev://tab/\(Self.tab)"), scheme: "cmux") == nil)
        #expect(DeepLink.parse(Self.url("cmux://tab/\(Self.tab)"), scheme: "cmux-dev-mytag") == nil)
        for other in ["https://cmux.com/tab/\(Self.tab)", "file:///tab/\(Self.tab)", "ssh://tab/\(Self.tab)"] {
            #expect(DeepLink.parse(Self.url(other), scheme: "cmux") == nil, "\(other)")
        }
    }

    @Test func theSignInCallbackIsNeverALink() {
        for text in ["cmux://auth-callback", "cmux://auth-callback?code=abc&state=xyz", "cmux://AUTH-CALLBACK/x"] {
            #expect(DeepLink.parse(Self.url(text), scheme: "cmux") == nil, "\(text)")
        }
        #expect(DeepLink.authCallbackHost == "auth-callback")
    }

    @Test func unknownHostsAreNotLinks() {
        for text in ["cmux://screen/screen_\(Self.hex)", "cmux://window/\(Self.tab)", "cmux://open?url=https://x",
                     "cmux://\(Self.tab)", "cmux:tab/\(Self.tab)", "cmux://"] {
            #expect(DeepLink.parse(Self.url(text), scheme: "cmux") == nil, "\(text)")
        }
    }

    @Test func malformedIDsAreNotLinks() {
        let bad = [
            "cmux://tab/tab_0123", // too short
            "cmux://tab/tab_\(Self.hex)00", // too long
            "cmux://tab/tab_0123456789ABCDEF0123456789ABCDEF", // uppercase hex
            "cmux://tab/tab_0123456789abcdef0123456789abcdeg", // not hex
            "cmux://tab/\(Self.pane)", // another kind's prefix
            "cmux://pane/\(Self.tab)",
            "cmux://workspace/\(Self.tab)",
            "cmux://tab/7", // a numeric handle
            "cmux://pane/pane:3",
            "cmux://workspace/workspace:1",
            "cmux://tab/\(Self.tab)/extra",
            "cmux://tab/",
            "cmux://tab/\(Self.tab)#turn-1",
            "cmux://session/a%2Fb",
            "cmux://session/has%20space",
            "cmux://session/s1#notaturn",
            "cmux://session/s1#turn-",
            "cmux://tab/\(Self.tab)?machine=machine_1",
            "cmux://user@tab/\(Self.tab)",
            "cmux://tab:80/\(Self.tab)",
        ]
        for text in bad {
            #expect(DeepLink.parse(Self.url(text), scheme: "cmux") == nil, "\(text)")
        }
        #expect(DeepLink(.tab("tab_7")).url(scheme: "cmux") == nil, "formatting refuses an id that would not parse")
        #expect(DeepLink(.session("a/b", turn: nil)).url(scheme: "cmux") == nil)
        #expect(DeepLink(.tab(Self.tab), machine: "m1").url(scheme: "cmux") == nil)
        #expect(DeepLink(.tab(Self.tab)).url(scheme: "1cmux") == nil)
    }

    /// Only `machine` is read from the query, so a page or another app
    /// cannot use a link as a command channel.
    @Test func extraQueryParametersAreIgnored() {
        let text = "cmux://tab/\(Self.tab)?command=rm%20-rf&focus=1&machine=\(Self.machine)&initial_command=x"
        #expect(DeepLink.parse(Self.url(text), scheme: "cmux") == DeepLink(.tab(Self.tab), machine: Self.machine))
        #expect(DeepLink.parse(Self.url("cmux://workspace/\(Self.workspace)?x=1"), scheme: "cmux")
            == DeepLink(.workspace(Self.workspace)))
        #expect(DeepLink.parse(Self.url("cmux://session/s1?send=hi#turn-t1"), scheme: "cmux") == DeepLink(.session("s1", turn: "t1")))
    }

    @Test func hostsAreCaseInsensitive() {
        #expect(DeepLink.parse(Self.url("cmux://TAB/\(Self.tab)"), scheme: "cmux") == DeepLink(.tab(Self.tab)))
    }

    @Test func nightlyLinksParse() throws {
        let a = Self.uuidA.uuidString, b = Self.uuidB.uuidString, c = Self.uuidC.uuidString
        let cases: [(String, DeepLink.Target)] = [
            ("cmux://workspace/\(a)", .legacyWorkspace(Self.uuidA, fallback: nil)),
            ("cmux://workspace/\(a.lowercased())", .legacyWorkspace(Self.uuidA, fallback: nil)),
            ("cmux://workspace/\(a)?stable_workspace_id=\(b)", .legacyWorkspace(Self.uuidA, fallback: Self.uuidB)),
            ("cmux://workspace/\(a)/pane/\(b)", .legacyPane(workspace: Self.uuidA, pane: Self.uuidB)),
            ("cmux://workspace/\(a)/surface/\(b)",
             .legacySurface(workspace: Self.uuidA, surface: Self.uuidB, fallbackWorkspace: nil, fallbackSurface: nil)),
            ("cmux://workspace/\(a)/panel/\(b)",
             .legacySurface(workspace: Self.uuidA, surface: Self.uuidB, fallbackWorkspace: nil, fallbackSurface: nil)),
            ("cmux://workspace/\(a)/surface/\(b)?stable_workspace_id=\(c)&stable_surface_id=\(a)",
             .legacySurface(workspace: Self.uuidA, surface: Self.uuidB, fallbackWorkspace: Self.uuidC, fallbackSurface: Self.uuidA)),
        ]
        for (text, target) in cases {
            #expect(DeepLink.parse(Self.url(text), scheme: "cmux") == DeepLink(target), "\(text)")
        }
        // Nightly's own formatting round-trips.
        for (_, target) in cases {
            let url = try #require(DeepLink(target).url(scheme: "cmux"))
            #expect(DeepLink.parse(url, scheme: "cmux") == DeepLink(target), "\(url)")
        }
        #expect(DeepLink(.legacyPane(workspace: Self.uuidA, pane: Self.uuidB)).url(scheme: "cmux")?.absoluteString
            == "cmux://workspace/\(a)/pane/\(b)")
    }

    @Test func malformedNightlyLinksAreNotLinks() {
        let a = Self.uuidA.uuidString
        for text in ["cmux://workspace/\(a)/pane", "cmux://workspace/\(a)/pane/not-a-uuid", "cmux://workspace/\(a)/window/\(a)",
                     "cmux://workspace/\(a)/pane/\(a)/extra", "cmux://workspace/\(a)?stable_workspace_id=nope",
                     "cmux://workspace/\(a)/surface/\(a)?stable_surface_id=nope", "cmux://workspace/\(a)#x"] {
            #expect(DeepLink.parse(Self.url(text), scheme: "cmux") == nil, "\(text)")
        }
    }
}
