import Testing
@testable import CmuxTerminal

struct TerminalSurfaceLoginShellArgumentsResolverTests {
    @Test func buildsLoginArgumentsFromOwnedPasswordRecordValues() {
        let resolver = TerminalSurfaceLoginShellArgumentsResolver {
            (name: "tester", shell: "/opt/homebrew/bin/fish")
        }

        #expect(resolver.resolve() == [
            "/usr/bin/login", "-flp", "tester",
            "/bin/bash", "--noprofile", "--norc", "-c",
            "exec -l -- \"$1\"", "cmux-login-shell", "/opt/homebrew/bin/fish",
        ])
    }

    @Test func passesLoginShellPathAsDataInsteadOfShellSyntax() {
        let resolver = TerminalSurfaceLoginShellArgumentsResolver {
            (name: "tester", shell: "/tmp/shell path; touch /tmp/cmux-injected")
        }

        #expect(resolver.resolve() == [
            "/usr/bin/login", "-flp", "tester",
            "/bin/bash", "--noprofile", "--norc", "-c",
            "exec -l -- \"$1\"", "cmux-login-shell",
            "/tmp/shell path; touch /tmp/cmux-injected",
        ])
    }

    @Test func missingPasswordRecordUsesSafeFallback() {
        let resolver = TerminalSurfaceLoginShellArgumentsResolver { nil }

        #expect(resolver.resolve() == ["/bin/zsh", "-l"])
    }

    @Test func unnamedPasswordRecordUsesItsShellDirectly() {
        let resolver = TerminalSurfaceLoginShellArgumentsResolver {
            (name: "", shell: "/bin/ksh")
        }

        #expect(resolver.resolve() == ["/bin/ksh", "-l"])
    }
}
