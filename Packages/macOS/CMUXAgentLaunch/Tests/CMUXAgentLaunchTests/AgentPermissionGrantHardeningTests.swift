import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Each test here is a bypass found in security review of batch grants: a
/// request an approved rule must never auto-answer, or a rule the approval
/// panel must flag as broad.
@Suite("Agent permission grant hardening")
struct AgentPermissionGrantHardeningTests {
    private typealias Matcher = AgentPermissionRuleMatcher

    /// A canonical temporary directory that is removed when the test ends.
    private final class Sandbox {
        let root: URL
        let outside: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("grant-hardening-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("repo", isDirectory: true)
            outside = base.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        var rule: String { "Edit(/\(root.path)/**)" }

        func path(_ relative: String) -> String { root.path + "/" + relative }

        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func fileRequest(_ tool: String, _ path: String, cwd: String = "/tmp") -> AgentPermissionRequest {
        AgentPermissionRequest(toolName: tool, filePath: path, cwd: cwd)
    }

    private func bash(_ command: String) -> AgentPermissionRequest {
        AgentPermissionRequest(toolName: "Bash", command: command, cwd: "/tmp")
    }

    private func parse(_ rules: [String], reason: String? = nil) -> Result<AgentPermissionGrantProposal, AgentPermissionGrantProposal.ValidationError> {
        var params: [String: Any] = ["rules": rules, "scope": "session", "session_id": "s1"]
        if let reason { params["reason"] = reason }
        return AgentPermissionGrantProposal.parse(params: params)
    }

    // MARK: File tools

    @Test(arguments: ["Write", "MultiEdit", "NotebookEdit", "Edit", "Grep", "Glob", "LS", "Read"])
    func fileToolRuleWithoutAPathNeverMatchesAndIsRejected(tool: String) {
        #expect(!Matcher().allows(rule: tool, request: fileRequest(tool, "/etc/hosts")))
        #expect(parse([tool]) == .failure(.invalidRule(tool)))
    }

    @Test func writeAndGrepRulesUseEditAndReadPathSemantics() throws {
        let sandbox = try Sandbox()
        let inside = sandbox.path("a.swift")
        #expect(Matcher().allows(rule: "Write(/\(sandbox.root.path)/**)", request: fileRequest("Edit", inside)))
        #expect(!Matcher().allows(rule: "Write(/\(sandbox.root.path)/**)", request: fileRequest("Write", "/etc/hosts")))
        #expect(Matcher().allows(rule: "Grep(/\(sandbox.root.path)/**)", request: fileRequest("Read", inside)))
        #expect(!Matcher().allows(rule: "Grep(/\(sandbox.root.path)/**)", request: fileRequest("Edit", inside)))
    }

    // MARK: Paths

    @Test func dotDotThroughASymlinkNeverMatches() throws {
        let sandbox = try Sandbox()
        let nested = sandbox.outside.appendingPathComponent("deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("link"), withDestinationPath: nested.path)
        // Lexically `/repo/x`; the kernel resolves it to `outside/x`.
        #expect(!Matcher().allows(rule: sandbox.rule, request: fileRequest("Edit", sandbox.path("link/../x"))))
        #expect(!Matcher().allows(rule: sandbox.rule, request: fileRequest("Edit", sandbox.path("sub/../a.swift"))))
    }

    @Test func symlinkComponentUnderTheRootNeverMatches() throws {
        let sandbox = try Sandbox()
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("inner"), withDestinationPath: sandbox.root.path)
        #expect(!Matcher().allows(rule: sandbox.rule, request: fileRequest("Edit", sandbox.path("inner/a.swift"))))
        #expect(Matcher().allows(rule: sandbox.rule, request: fileRequest("Edit", sandbox.path("real/a.swift"))))
    }

    @Test func danglingSymlinkLeafNeverMatches() throws {
        let sandbox = try Sandbox()
        let target = sandbox.outside.appendingPathComponent("not-yet-created").path
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("leaf"), withDestinationPath: target)
        #expect(!Matcher().allows(rule: sandbox.rule, request: fileRequest("Write", sandbox.path("leaf"))))
    }

    @Test(arguments: [
        ".git/hooks/pre-commit", ".git/config", "sub/.git/HEAD", ".claude/settings.json",
        ".claude/settings.local.json", ".mcp.json", "sub/.envrc",
    ])
    func protectedPathsNeverMatch(relative: String) throws {
        let sandbox = try Sandbox()
        #expect(!Matcher().allows(rule: sandbox.rule, request: fileRequest("Edit", sandbox.path(relative))))
        #expect(!Matcher().allows(rule: "Read(/\(sandbox.root.path)/**)", request: fileRequest("Read", sandbox.path(relative))))
    }

    @Test(arguments: [
        ".ssh/id_ed25519", ".ssh/config", ".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile",
        "Library/LaunchAgents/x.plist", ".config/cmux/cmux.json", ".cmuxterm/agent-permission-grants.json",
    ])
    func protectedHomePathsNeverMatch(relative: String) {
        let home = NSHomeDirectory()
        #expect(!Matcher().allows(rule: "Read(~/**)", request: fileRequest("Read", home + "/" + relative)))
        #expect(!Matcher().allows(rule: "Edit(//\(home.dropFirst())/**)", request: fileRequest("Edit", home + "/" + relative)))
    }

    @Test func globWithAnAbsoluteOrParentPatternNeverMatches() throws {
        let sandbox = try Sandbox()
        let rule = "Read(/\(sandbox.root.path)/**)"
        func glob(_ pattern: String) -> AgentPermissionRequest {
            AgentPermissionRequest(toolName: "Glob", pattern: pattern, cwd: sandbox.root.path)
        }
        #expect(Matcher().allows(rule: rule, request: glob("**/*.swift")))
        #expect(!Matcher().allows(rule: rule, request: glob("/etc/*")))
        #expect(!Matcher().allows(rule: rule, request: glob("../outside/*")))
        #expect(!Matcher().allows(rule: rule, request: glob("~/.ssh/*")))
    }

    // MARK: Bash

    @Test(arguments: [
        "ls =(touch x)", "ls *(e:'touch x':)", "ls *", "ls {a,b}", "ls ~", "ls $HOME", "ls a\\ b",
        "ls \"a\"", "ls a'b'c'", "ls !x", "ls [ab]", "ls ?", "ls #x", "ls ^x", "ls\tx", "ls a\nb",
        "FOO=1 ls", "=ls", "ls =ls",
    ])
    func shellWordsOutsideTheAllowlistNeverMatch(command: String) {
        #expect(!Matcher().allows(rule: "Bash(ls:*)", request: bash(command)), "\(command)")
    }

    @Test func gitConfigInjectionIsBroadAndUnquotedAliasesNeverMatch() {
        #expect(!Matcher().allows(rule: "Bash(git:*)", request: bash("git -c alias.x='!sh' x")))
        #expect(Matcher().isBroad("Bash(git:*)"))
        #expect(Matcher().isBroad("Bash(git *)"))
        #expect(Matcher().isBroad("Bash(git status:*)"))
        #expect(!Matcher().isBroad("Bash(git status)"))
    }

    @Test func prefixRulesCompareWholeWords() {
        #expect(Matcher().allows(rule: "Bash(gh pr view:*)", request: bash("gh  pr view 12")))
        #expect(Matcher().allows(rule: "Bash(git commit -m:*)", request: bash("git commit -m 'fix the thing'")))
        #expect(!Matcher().allows(rule: "Bash(gh pr:*)", request: bash("gh prx view")))
        #expect(!Matcher().allows(rule: "Bash(ls:*)", request: bash("/bin/ls")))
    }

    @Test(arguments: [
        "Bash(/bin/sh:*)", "Bash(/usr/bin/env:*)", "Bash(python3:*)", "Bash(npx:*)", "Bash(xargs:*)",
        "Bash(find:*)", "Bash(curl:*)", "Bash(ssh:*)", "Bash(make:*)", "Bash(osascript:*)", "Bash(/bin/sh)",
        "Bash(*)", "Bash", "Bash( :*)",
    ])
    func shellsInterpretersAndWrappersAreBroad(rule: String) {
        #expect(Matcher().isBroad(rule), "\(rule)")
    }

    // MARK: Path breadth

    @Test(arguments: ["Edit(//./**)", "Edit(//Users/**)", "Read(//**)", "Edit(~/**)", "Edit(~)",
                      "Edit(~/.ssh/**)", "Read(~/Library/**)", "Edit(~/.claude/**)", "Edit(~/.zshrc)"])
    func rootsAtOrAboveHomeOrProtectedAreBroad(rule: String) {
        #expect(Matcher().isBroad(rule), "\(rule)")
    }

    @Test(arguments: ["Edit(//a/../b/**)", "Edit(~/../x/**)", "Edit(src/**)", "Edit(//a/*.swift)"])
    func malformedPathRulesAreRejected(rule: String) {
        #expect(parse([rule]) == .failure(.invalidRule(rule)))
    }

    // MARK: WebFetch

    @Test(arguments: [
        "https://evil.com\\@example.com/", "https://user@example.com/", "https://evil.com%2F@example.com/",
        "https://exa mple.com/", "ftp://example.com/", "https://EXAMPLE.com.evil.net/", "https://[::1]/",
        "file:///etc/passwd",
    ])
    func webFetchAuthorityTricksNeverMatch(url: String) {
        let request = AgentPermissionRequest(toolName: "WebFetch", url: url)
        #expect(!Matcher().allows(rule: "WebFetch(domain:example.com)", request: request), "\(url)")
    }

    @Test func webFetchMatchesHostAndSubdomainsOnly() {
        func fetch(_ url: String) -> AgentPermissionRequest { AgentPermissionRequest(toolName: "WebFetch", url: url) }
        #expect(Matcher().allows(rule: "WebFetch(domain:example.com)", request: fetch("https://Docs.Example.com:443/a?b")))
        #expect(Matcher().allows(rule: "WebFetch(domain:example.com)", request: fetch("http://example.com")))
        #expect(!Matcher().allows(rule: "WebFetch(domain:example.com)", request: fetch("https://badexample.com/")))
        #expect(Matcher().isBroad("WebFetch(domain:com)"))
        #expect(Matcher().isBroad("WebFetch"))
        #expect(!Matcher().isBroad("WebFetch(domain:example.com)"))
        #expect(parse(["WebFetch(domain:exa_mple.com)"]) == .failure(.invalidRule("WebFetch(domain:exa_mple.com)")))
    }

    // MARK: Text

    @Test(arguments: ["Bash(git status\u{202E})", "Bash(git\u{200B}status)", "Bash(ls\u{0007})", "WebSearch\u{FEFF}"])
    func invisibleOrControlCharactersInRulesAreRejected(rule: String) {
        #expect(parse([rule]) == .failure(.invalidRule(rule)))
    }

    @Test func reasonNewlinesCollapseAndControlCharactersAreRejected() {
        #expect(parse(["Bash(git status)"], reason: "line one\n\nline two\r\tend").map(\.reason)
            == .success("line one line two end"))
        #expect(parse(["Bash(git status)"], reason: "trust me\u{202E}") == .failure(.invalidReason))
    }

    // MARK: Persistence

    @Test func handWrittenGrantsWithoutExpiryOrWithInvalidRulesAreDroppedOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("grants.json")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let farFuture = ISO8601DateFormatter().string(from: now.addingTimeInterval(365 * 86_400))
        let granted = ISO8601DateFormatter().string(from: now)
        func grant(_ rules: String, expires: String) -> String {
            #"{"id":"\#(UUID().uuidString)","rules":[\#(rules)],"scope":{"session":{"id":"s1"}},"grantedAt":"\#(granted)","useCount":0\#(expires)}"#
        }
        let json = #"{"version":1,"grants":["#
            + [
                grant(#""Bash(ls:*)""#, expires: #","expiresAt":null"#),
                grant(#""Bash(ls:*)""#, expires: ""),
                grant(#""Write""#, expires: #","expiresAt":"\#(later)""#),
                grant(#""Bash(ls:*)""#, expires: #","expiresAt":"\#(farFuture)""#),
                grant(#""Bash(make test)""#, expires: #","expiresAt":"\#(later)""#),
            ].joined(separator: ",")
            + "]}"
        try Data(json.utf8).write(to: file)
        let loaded = AgentPermissionGrantStore(fileURL: file).grants(now: now)
        #expect(loaded.map(\.rules) == [["Bash(make test)"]])
    }
}
