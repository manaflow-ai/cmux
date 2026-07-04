import Testing

@testable import CmuxFoundation

/// In-memory ``SSHConfigFileReading`` fake backed by a path → contents map.
///
/// Glob expansion matches the map's keys with shell-style `*`/`?` wildcards
/// where `*` does not cross `/`, mirroring `glob(3)` used by the real reader.
private struct InMemorySSHConfigFileReader: SSHConfigFileReading {
    var files: [String: String]

    func contentsOfFile(atPath path: String) -> String? {
        files[path]
    }

    func filePaths(matchingGlob pattern: String) -> [String] {
        files.keys.filter { Self.matches(path: $0, pattern: pattern) }.sorted()
    }

    private static func matches(path: String, pattern: String) -> Bool {
        matches(
            path: Substring(path),
            pattern: Substring(pattern)
        )
    }

    private static func matches(path: Substring, pattern: Substring) -> Bool {
        var path = path
        var pattern = pattern
        while let patternCharacter = pattern.first {
            switch patternCharacter {
            case "*":
                let rest = pattern.dropFirst()
                var candidate = path
                while true {
                    if matches(path: candidate, pattern: rest) { return true }
                    guard let next = candidate.first, next != "/" else { return false }
                    candidate = candidate.dropFirst()
                }
            case "?":
                guard let next = path.first, next != "/" else { return false }
                path = path.dropFirst()
                pattern = pattern.dropFirst()
            default:
                guard path.first == patternCharacter else { return false }
                path = path.dropFirst()
                pattern = pattern.dropFirst()
            }
        }
        return path.isEmpty
    }
}

@Suite struct SSHConfigHostAliasScannerTests {
    private let home = "/Users/tester"

    private func scanner(files: [String: String]) -> SSHConfigHostAliasScanner {
        SSHConfigHostAliasScanner(
            fileReader: InMemorySSHConfigFileReader(files: files),
            homeDirectory: home
        )
    }

    private func aliases(config: String, extraFiles: [String: String] = [:]) -> [String] {
        var files = extraFiles
        files["\(home)/.ssh/config"] = config
        let scanner = scanner(files: files)
        return scanner.hostAliases(inConfigAtPath: scanner.defaultUserConfigPath)
    }

    // MARK: - Plain hosts

    @Test func plainHostsAreListedInEncounterOrder() {
        let config = """
        Host alpha
            HostName alpha.example.com
            User deploy
        Host beta gamma
            Port 2222
        """
        #expect(aliases(config: config) == ["alpha", "beta", "gamma"])
    }

    @Test func hostBlockOptionsDoNotLeakAliases() {
        // `HostName`, `User`, and friends start with "host"-adjacent keywords and
        // must never be mistaken for `Host` lines.
        let config = """
        Host alpha
            HostName real.example.com
            HostbasedAuthentication no
            User bob
        """
        #expect(aliases(config: config) == ["alpha"])
    }

    @Test func duplicateAliasesAreDeduplicatedKeepingFirstOccurrence() {
        let config = """
        Host alpha beta
        Host beta alpha gamma
        """
        #expect(aliases(config: config) == ["alpha", "beta", "gamma"])
    }

    @Test func hostLineWithoutArgumentsIsIgnored() {
        let config = """
        Host
        Host alpha
        """
        #expect(aliases(config: config) == ["alpha"])
    }

    // MARK: - Wildcards and negations

    @Test func wildcardAndNegatedPatternsAreExcluded() {
        let config = """
        Host *
            ServerAliveInterval 60
        Host web-* db?
        Host !bastion prod
        Host staging-?.example
        """
        #expect(aliases(config: config) == ["prod"])
    }

    @Test func quotedWildcardPatternsAreStillExcluded() {
        let config = """
        Host "web*" "exact host"
        """
        #expect(aliases(config: config) == ["exact host"])
    }

    @Test func leadingDashAliasesAreExcluded() {
        // `cmux ssh` (like plain `ssh <destination>`) cannot take a
        // destination starting with `-`, so such aliases are not connectable.
        let config = """
        Host -weird ok
        """
        #expect(aliases(config: config) == ["ok"])
    }

    // MARK: - Match blocks

    @Test func matchBlocksAreIgnored() {
        let config = """
        Host alpha
        Match host "*.corp" user deploy
            ProxyJump bastion
        Match exec "test -f /tmp/flag"
            User other
        Host beta
        """
        #expect(aliases(config: config) == ["alpha", "beta"])
    }

    @Test func matchCriteriaNeverLeakAliases() {
        let config = """
        Match host bastion
            User deploy
        """
        #expect(aliases(config: config) == [])
    }

    // MARK: - Comments, whitespace, separators

    @Test func commentsAndBlankLinesAreIgnored() {
        let config = """
        # Global comment
           # Indented comment

        Host alpha # trailing comment with words
        Host beta
        """
        #expect(aliases(config: config) == ["alpha", "beta"])
    }

    @Test func keywordsAreCaseInsensitiveAndAllowEqualsSeparator() {
        let config = """
        host alpha
        HOST beta
        HoSt=gamma
        Host = delta
        """
        #expect(aliases(config: config) == ["alpha", "beta", "gamma", "delta"])
    }

    @Test func quotedAliasesKeepSpaces() {
        let config = """
        Host "my host" plain
        """
        #expect(aliases(config: config) == ["my host", "plain"])
    }

    @Test func carriageReturnLineEndingsAreSupported() {
        let config = "Host alpha\r\nHost beta\r\n"
        #expect(aliases(config: config) == ["alpha", "beta"])
    }

    // MARK: - Include directives

    @Test func includeWithTildePathIsFollowed() {
        let config = """
        Host alpha
        Include ~/.ssh/extra
        """
        let extra = """
        Host included
        """
        #expect(
            aliases(config: config, extraFiles: ["\(home)/.ssh/extra": extra])
                == ["alpha", "included"]
        )
    }

    @Test func includeWithRelativePathResolvesAgainstDotSSH() {
        let config = """
        Include config.d/work
        """
        let work = """
        Host work-box
        """
        #expect(
            aliases(config: config, extraFiles: ["\(home)/.ssh/config.d/work": work])
                == ["work-box"]
        )
    }

    @Test func includeWithAbsolutePathIsFollowed() {
        let config = """
        Include /etc/ssh/shared_config
        """
        let shared = """
        Host shared-box
        """
        #expect(
            aliases(config: config, extraFiles: ["/etc/ssh/shared_config": shared])
                == ["shared-box"]
        )
    }

    @Test func includeGlobExpandsInSortedOrder() {
        let config = """
        Include config.d/*
        """
        let files = [
            "\(home)/.ssh/config.d/b-hosts": "Host bravo",
            "\(home)/.ssh/config.d/a-hosts": "Host apple",
        ]
        #expect(aliases(config: config, extraFiles: files) == ["apple", "bravo"])
    }

    @Test func includeAcceptsMultipleArguments() {
        let config = """
        Include config.d/one config.d/two
        """
        let files = [
            "\(home)/.ssh/config.d/one": "Host one-box",
            "\(home)/.ssh/config.d/two": "Host two-box",
        ]
        #expect(aliases(config: config, extraFiles: files) == ["one-box", "two-box"])
    }

    @Test func missingIncludeTargetIsIgnored() {
        let config = """
        Include config.d/missing
        Host after
        """
        #expect(aliases(config: config) == ["after"])
    }

    @Test func includedFilesAreDeduplicatedAgainstMainConfig() {
        let config = """
        Host alpha
        Include ~/.ssh/extra
        """
        let extra = """
        Host alpha beta
        """
        #expect(
            aliases(config: config, extraFiles: ["\(home)/.ssh/extra": extra])
                == ["alpha", "beta"]
        )
    }

    @Test func nestedIncludesAreFollowed() {
        let config = """
        Include level1
        """
        let files = [
            "\(home)/.ssh/level1": "Host one\nInclude level2",
            "\(home)/.ssh/level2": "Host two",
        ]
        #expect(aliases(config: config, extraFiles: files) == ["one", "two"])
    }

    @Test func includeCyclesTerminateAndStillCollectAliases() {
        let config = """
        Include loop-a
        """
        let files = [
            "\(home)/.ssh/loop-a": "Host from-a\nInclude loop-b",
            "\(home)/.ssh/loop-b": "Host from-b\nInclude loop-a",
        ]
        #expect(aliases(config: config, extraFiles: files) == ["from-a", "from-b"])
    }

    // MARK: - Missing config

    @Test func missingConfigFileYieldsEmptyList() {
        let scanner = scanner(files: [:])
        #expect(scanner.hostAliases(inConfigAtPath: scanner.defaultUserConfigPath) == [])
    }

    @Test func defaultUserConfigPathIsUnderHome() {
        let scanner = scanner(files: [:])
        #expect(scanner.defaultUserConfigPath == "/Users/tester/.ssh/config")
    }
}
