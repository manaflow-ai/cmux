import Foundation
import Testing
@testable import CmuxNextOnboarding

@Suite struct RouterTests {
    let router = ExternalOpenRouter(
        isDirectory: { $0.hasSuffix("/dir") || $0 == "/Users/me/Projects" },
        isExecutable: { $0.hasSuffix("run.command") || $0.hasSuffix("/bin/tool") }
    )

    @Test func webLinksOpenBrowserTabs() {
        let url = URL(string: "https://cmux.com/docs?x=1#y")!
        #expect(router.route(url) == .browserTab(url))
        #expect(router.route(URL(string: "HTTP://example.com")!) == .browserTab(URL(string: "HTTP://example.com")!))
        #expect(router.route(URL(fileURLWithPath: "/tmp/page.html")) == .browserTab(URL(fileURLWithPath: "/tmp/page.html")))
    }

    @Test func sshLinksBecomeQuotedSshCommands() {
        #expect(router.route(URL(string: "ssh://example.com")!) == .terminal(cwd: nil, command: "ssh -- 'example.com'"))
        #expect(router.route(URL(string: "ssh://me@example.com:2222")!) == .terminal(cwd: nil, command: "ssh -p 2222 -- 'me@example.com'"))
        #expect(router.route(URL(string: "ssh://[::1]:22")!) == .terminal(cwd: nil, command: "ssh -p 22 -- '[::1]'"))
    }

    @Test func craftedSshLinksAreRefused() {
        for text in ["ssh://-oProxyCommand=evil", "ssh://host;rm%20-rf%20~", "ssh://me%27@host", "ssh://-me@host", "ssh://ho%20st", "ssh:///nohost"] {
            #expect(router.route(URL(string: text)!) == .unsupported, "\(text)")
        }
    }

    @Test func manPageLinks() {
        #expect(router.route(URL(string: "x-man-page://ls")!) == .terminal(cwd: nil, command: "man 'ls'"))
        #expect(router.route(URL(string: "x-man-page://1/printf")!) == .terminal(cwd: nil, command: "man '1' 'printf'"))
        #expect(router.route(URL(string: "x-man-page:///git-log")!) == .terminal(cwd: nil, command: "man 'git-log'"))
        #expect(router.route(URL(string: "x-man-page://ls;reboot")!) == .unsupported)
        #expect(router.route(URL(string: "x-man-page://-P%20evil/ls")!) == .unsupported)
        #expect(router.route(URL(string: "x-man-page://")!) == .unsupported)
    }

    @Test func scriptsRunInTheirFolder() {
        #expect(router.route(URL(fileURLWithPath: "/Users/me/run.command")) == .terminal(cwd: "/Users/me", command: "'/Users/me/run.command'"))
        #expect(router.route(URL(fileURLWithPath: "/Users/me/it's.sh")) == .terminal(cwd: "/Users/me", command: #"sh '/Users/me/it'\''s.sh'"#))
        #expect(router.route(URL(fileURLWithPath: "/tmp/setup.zsh")) == .terminal(cwd: "/tmp", command: "zsh '/tmp/setup.zsh'"))
        #expect(router.route(URL(fileURLWithPath: "/opt/bin/tool")) == .terminal(cwd: "/opt/bin", command: "'/opt/bin/tool'"))
        #expect(router.route(URL(fileURLWithPath: "/tmp/notes.txt")) == .unsupported)
    }

    @Test func foldersOpenATerminalThere() {
        #expect(router.route(URL(fileURLWithPath: "/Users/me/Projects")) == .terminal(cwd: "/Users/me/Projects", command: nil))
        #expect(router.newTabHere("/Users/me/Projects") == .terminal(cwd: "/Users/me/Projects", command: nil))
        #expect(router.newTabHere("/Users/me/Projects/readme.md") == .terminal(cwd: "/Users/me/Projects", command: nil))
    }

    @Test func otherSchemesAreUnsupported() {
        #expect(router.route(URL(string: "mailto:me@example.com")!) == .unsupported)
        #expect(router.route(URL(string: "javascript:alert(1)")!) == .unsupported)
    }

    @Test func shellQuoting() {
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.quote("$(x)`y`") == "'$(x)`y`'")
    }
}
