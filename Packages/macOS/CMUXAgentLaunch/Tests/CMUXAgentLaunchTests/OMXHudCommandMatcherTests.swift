import Testing
@testable import CMUXAgentLaunch

@Suite("OMX HUD command matcher")
struct OMXHudCommandMatcherTests {
    private let matcher = OMXHudCommandMatcher()

    @Test("the invocations OMX produces match", arguments: [
        ["omx", "hud", "--watch"],
        ["oh-my-codex", "hud", "--watch"],
        ["/usr/local/bin/omx", "hud", "--watch"],
        ["node", "omx.js", "hud", "--watch"],
        ["node", "/opt/oh-my-codex/dist/omx.js", "hud", "--watch"],
        ["bun", "/opt/oh-my-codex/dist/cli/omx.mjs", "hud", "--watch"],
        ["node", "/usr/local/lib/node_modules/oh-my-codex/dist/cli/index.js", "hud", "--watch"],
        ["exec", "node", "/opt/oh-my-codex/dist/cli/omx.js", "hud", "--watch"],
        ["env", "OMX_SESSION_ID=s1", "node", "/opt/oh-my-codex/dist/cli/omx.js", "hud", "--watch"],
        ["exec", "env", "OMX_SESSION_ID=s1", "/usr/local/bin/node", "/opt/oh my codex/omx.js", "hud", "--watch", "focused"],
        ["OMX_TMUX_SPLIT_OPERATION_MARKER=m1", "exec", "env", "A=b", "node", "/opt/omx.js", "hud", "--watch"],
        ["OMX", "hud", "--watch"],
    ])
    func omxHudInvocationsMatch(words: [String]) {
        #expect(matcher.matches(words))
    }

    @Test("text that only mentions OMX and a HUD does not match", arguments: [
        [],
        ["hud", "--watch"],
        ["echo", "hud"],
        ["echo", "omx", "hud"],
        ["echo", "omx", "hud", "--watch"],
        ["echo", "notomx hud"],
        ["omx", "hud"],
        ["omx", "--watch", "hud"],
        ["omx", "run", "hud", "--watch"],
        ["omxhud", "hud", "--watch"],
        ["vim", "omx-hud-notes.md", "--watch"],
        ["node", "/opt/tools/report.js", "hud", "--watch"],
        ["node", "--eval", "omx.js", "hud", "--watch"],
        ["cd", "/tmp", "&&", "omx", "hud", "--watch"],
        ["omx", "hud", "--watch;", "rm", "-rf", "build"],
        ["omx", "hud", "--watch", ";", "rm", "-rf", "build"],
        ["omx", "hud", "--watch", "&&", "curl", "example.com"],
        ["omx", "hud", "--watch", "$(id)"],
        ["env", "OMX_SESSION_ID=s1"],
    ])
    func looseMentionsDoNotMatch(words: [String]) {
        #expect(!matcher.matches(words))
    }

    /// Through the OMX shim the caller is known, so a development entry script
    /// with any name counts; the command still has to be `hud --watch`.
    @Test("the OMX shim vouches for the entry script, not for the command")
    func shimLaunchAcceptsAnyEntryScriptOnly() {
        let developmentCheckout = ["node", "/src/oh-my-dev/dist/cli/index.js", "hud", "--watch"]
        #expect(!matcher.matches(developmentCheckout))
        #expect(matcher.matches(developmentCheckout, launchedThroughOMXShim: true))

        #expect(!matcher.matches(["echo", "hud"], launchedThroughOMXShim: true))
        #expect(!matcher.matches(["echo", "hud", "--watch"], launchedThroughOMXShim: true))
        #expect(!matcher.matches(["node", "/src/index.js", "hud"], launchedThroughOMXShim: true))
        #expect(!matcher.matches(["hud", "--watch"], launchedThroughOMXShim: true))
    }
}
