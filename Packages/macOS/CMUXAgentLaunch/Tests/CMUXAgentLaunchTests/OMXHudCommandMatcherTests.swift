import Testing
@testable import CMUXAgentLaunch

@Suite("OMX HUD command matcher")
struct OMXHudCommandMatcherTests {
    private let matcher = OMXHudCommandMatcher()

    @Test("the invocations OMX produces match", arguments: [
        "omx hud --watch",
        "oh-my-codex hud --watch",
        "OMX hud --watch",
        "/usr/local/bin/omx hud --watch",
        "node omx.js hud --watch",
        "node /opt/oh-my-codex/dist/omx.js hud --watch",
        "bun /opt/oh-my-codex/dist/cli/omx.mjs hud --watch",
        "node /usr/local/lib/node_modules/oh-my-codex/dist/cli/index.js hud --watch",
        "exec node '/opt/oh-my-codex/dist/cli/omx.js' hud --watch",
        "env OMX_SESSION_ID=s1 node /opt/oh-my-codex/dist/cli/omx.js hud --watch",
        "exec env OMX_SESSION_ID='s 1' '/usr/local/bin/node' '/opt/oh my codex/omx.js' hud --watch focused",
        "OMX_TMUX_SPLIT_OPERATION_MARKER='m1' exec env OMX_TMUX_HUD_OWNER=%3 node /opt/omx.js hud --watch",
        // The runtime itself can live inside the package directory.
        "'/Users/me/oh-my-codex/.tools/node' '/Users/me/oh-my-codex/dist/cli/omx.js' hud --watch",
        // OMX quotes an apostrophe in a path as '\\''.
        "node '/Users/o'\\''brien/oh-my-codex/dist/cli/omx.js' hud --watch",
        "  omx   hud\t--watch  ",
        "env OMX_NOTE=a#b omx hud --watch",
    ])
    func omxHudInvocationsMatch(command: String) {
        #expect(matcher.matches(command: command))
    }

    @Test("text that only mentions OMX and a HUD does not match", arguments: [
        "",
        "hud --watch",
        "echo hud",
        "echo omx hud",
        "echo omx hud --watch",
        "echo 'notomx hud'",
        "omx hud",
        "omx --watch hud",
        "omx run hud --watch",
        "omxhud hud --watch",
        "vim omx-hud-notes.md --watch",
        "node /opt/tools/report.js hud --watch",
        "node --eval omx.js hud --watch",
        "/opt/oh-my-codex/bin/anything hud --watch",
        "env OMX_SESSION_ID=s1",
    ])
    func looseMentionsDoNotMatch(command: String) {
        #expect(!matcher.matches(command: command))
    }

    /// The caller hands the whole text to a shell, so a HUD invocation with
    /// anything else for that shell to run is not the HUD.
    @Test("a HUD invocation with more for the shell to run does not match", arguments: [
        "cd /tmp && omx hud --watch",
        "omx hud --watch; rm -rf build",
        "omx hud --watch ; rm -rf build",
        "omx hud --watch && curl example.com",
        "omx hud --watch | tee /tmp/log",
        "omx hud --watch > /tmp/log",
        "omx hud --watch &",
        "omx hud --watch\nrm -rf build",
        "omx hud --watch\r\nrm -rf build",
        "omx hud --watch $(id)",
        "omx hud --watch `id`",
        "omx hud --watch \"$(id)\"",
        "X=\"$(touch /tmp/marker)\" omx hud --watch",
        "X=`id` omx hud --watch",
        "node /opt/oh-my-codex/$(id)/omx.js hud --watch",
        "/tmp/$(id)/omx hud --watch",
        "(omx hud --watch)",
        "omx hud --watch # trailing",
        "omx hud --watch 'unterminated",
        "omx hud --watch \\",
        // A combining mark after a quote or operator must not hide it.
        "omx hud --watch 'a'\u{301}; touch marker; echo 'b'\u{301}",
        "omx hud --watch \"a\"\u{301}; touch marker; echo \"b\"\u{301}",
        "omx hud --watch ;\u{200D}touch marker",
        "omx hud --watch &\u{FE0F} touch marker",
        "omx hud --watch\u{2028}touch marker",
        "omx hud --watch\u{0}",
    ])
    func compoundCommandsDoNotMatch(command: String) {
        #expect(!matcher.matches(command: command))
        #expect(!matcher.matches(command: command, launchedThroughOMXShim: true))
    }

    @Test("shell operators inside single quotes are literal")
    func singleQuotedOperatorsAreLiteral() {
        #expect(matcher.matches(command: "env NOTE='a;b $(c)' omx hud --watch"))
    }

    /// Through the OMX shim the caller is known, so a development entry script
    /// with any name counts; the command still has to be `hud --watch`.
    @Test("the OMX shim vouches for the entry script, not for the command")
    func shimLaunchAcceptsAnyEntryScriptOnly() {
        let developmentCheckout = "node /src/oh-my-dev/dist/cli/index.js hud --watch"
        #expect(!matcher.matches(command: developmentCheckout))
        #expect(matcher.matches(command: developmentCheckout, launchedThroughOMXShim: true))

        #expect(!matcher.matches(command: "echo hud", launchedThroughOMXShim: true))
        #expect(!matcher.matches(command: "echo hud --watch", launchedThroughOMXShim: true))
        #expect(!matcher.matches(command: "node /src/index.js hud", launchedThroughOMXShim: true))
        #expect(!matcher.matches(command: "hud --watch", launchedThroughOMXShim: true))
    }
}
