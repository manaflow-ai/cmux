import Testing

@testable import CmuxFileSearch

@Suite("Query options to ripgrep arguments")
struct RipgrepArgumentsTests {
    private func globs(_ arguments: [String]) -> [String] {
        stride(from: 0, to: arguments.count - 1, by: 1)
            .filter { arguments[$0] == "--glob" }
            .map { arguments[$0 + 1] }
    }

    @Test("Default query: literal, case-insensitive, ignore files honored")
    func defaults() {
        let arguments = FileSearchQuery(pattern: "needle").ripgrepArguments(rootPath: "/root")

        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--no-config"))
        #expect(arguments.contains("--hidden"))
        #expect(arguments.contains("--ignore-case"))
        #expect(arguments.contains("--fixed-strings"))
        #expect(!arguments.contains("--word-regexp"))
        #expect(!arguments.contains("--no-ignore"))
        #expect(globs(arguments) == ["!.git", "!node_modules", "!dist", "!build", "!DerivedData"])
        #expect(Array(arguments.suffix(3)) == ["--", "needle", "/root"])
    }

    @Test("Match Case, Whole Word and Regex map to their flags")
    func toggles() {
        let query = FileSearchQuery(pattern: "a.b", isCaseSensitive: true, matchesWholeWord: true, isRegex: true)
        let arguments = query.ripgrepArguments(rootPath: "/root")

        #expect(arguments.contains("--case-sensitive"))
        #expect(!arguments.contains("--ignore-case"))
        #expect(arguments.contains("--word-regexp"))
        #expect(arguments.contains("--auto-hybrid-regex"))
        #expect(!arguments.contains("--fixed-strings"))
    }

    @Test("Turning off ignore files searches ignored and generated folders but never .git")
    func ignoreToggleOff() {
        let arguments = FileSearchQuery(pattern: "x", usesIgnoreFiles: false).ripgrepArguments(rootPath: "/root")

        #expect(arguments.contains("--no-ignore"))
        #expect(globs(arguments) == ["!.git"])
    }

    @Test("A pattern that looks like a flag stays the pattern")
    func dashPattern() {
        let arguments = FileSearchQuery(pattern: "--files").ripgrepArguments(rootPath: "/root")
        #expect(Array(arguments.suffix(3)) == ["--", "--files", "/root"])
    }

    @Test("Include and exclude fields become globs", arguments: [
        ("*.swift", ["*.swift"]),
        ("src", ["src", "**/src/**"]),
        ("./src/app/", ["src/app", "src/app/**"]),
        ("*.{ts,tsx}, docs", ["*.{ts,tsx}", "docs", "**/docs/**"]),
        ("  , ,", []),
        ("**/*.test.js", ["**/*.test.js"]),
    ])
    func includeGlobs(field: String, expected: [String]) {
        let query = FileSearchQuery(pattern: "x", includePatterns: field, usesIgnoreFiles: false)
        let arguments = query.ripgrepArguments(rootPath: "/root")
        #expect(globs(arguments) == ["!.git"] + expected)
    }

    @Test("Exclude entries are negated")
    func excludeGlobs() {
        let query = FileSearchQuery(pattern: "x", excludePatterns: "vendor, *.min.js", usesIgnoreFiles: false)
        let arguments = query.ripgrepArguments(rootPath: "/root")
        #expect(globs(arguments) == ["!.git", "!vendor", "!**/vendor/**", "!*.min.js"])
    }

    @Test("Commas inside braces do not split entries")
    func braceSplitting() {
        #expect(FileSearchGlobList("a,{b,c},d").entries == ["a", "{b,c}", "d"])
    }

    @Test("The local regex precheck rejects what cannot compile")
    func regexPrecheck() {
        #expect(FileSearchQuery(pattern: "(", isRegex: true).regexSyntaxError != nil)
        #expect(FileSearchQuery(pattern: "(", isRegex: false).regexSyntaxError == nil)
        #expect(FileSearchQuery(pattern: "a+b", isRegex: true).regexSyntaxError == nil)
    }
}
