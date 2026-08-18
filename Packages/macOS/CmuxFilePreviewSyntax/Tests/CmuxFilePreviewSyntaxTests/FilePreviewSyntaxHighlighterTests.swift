import Foundation
import Testing

@testable import CmuxFilePreviewSyntax

@Suite("File preview syntax highlighting")
struct FilePreviewSyntaxHighlighterTests {
    private let resolver = FilePreviewSyntaxLanguageResolver()
    private let highlighter = FilePreviewSyntaxHighlighter()

    @Test("Common standalone filenames resolve to a language")
    func commonFilenamesResolve() {
        let cases: [(String, FilePreviewSyntaxLanguage)] = [
            ("main.swift", .swift),
            ("query.sql", .sql),
            ("app.py", .python),
            ("worker.pyw", .python),
            ("index.ts", .typescript),
            ("component.tsx", .typescript),
            ("server.mjs", .javascript),
            ("main.go", .go),
            ("lib.rs", .rust),
            ("Widget.mm", .objc),
            ("styles.scss", .css),
            ("data.jsonc", .json),
            ("config.yml", .yaml),
            ("Cargo.toml", .toml),
            ("settings.properties", .ini),
            ("Dockerfile", .shell),
            (".zshrc", .shell),
        ]

        for (filename, expected) in cases {
            #expect(resolver.language(forFilename: filename) == expected)
        }
    }

    @Test("Unsupported standalone filenames remain plain text")
    func unsupportedFilenamesDoNotResolve() {
        for filename in ["README", "notes.txt", "photo.png", "archive.zip", "data.bin"] {
            #expect(resolver.language(forFilename: filename) == nil)
        }
    }

    @Test("The setting and resolved language gate highlighting")
    func policyHonorsToggleAndLanguage() {
        let policy = FilePreviewSyntaxHighlightPolicy()
        #expect(policy.allowsHighlighting(enabled: true, language: .swift, utf16Length: 10))
        #expect(!policy.allowsHighlighting(enabled: false, language: .swift, utf16Length: 10))
        #expect(!policy.allowsHighlighting(enabled: true, language: nil, utf16Length: 10))
    }

    @Test("Oversized sources degrade before scanning")
    func oversizedSourcesDegradeToPlainText() {
        let policy = FilePreviewSyntaxHighlightPolicy(maximumUTF16Length: 5)
        #expect(policy.allowsHighlighting(enabled: true, language: .swift, utf16Length: 5))
        #expect(!policy.allowsHighlighting(enabled: true, language: .swift, utf16Length: 6))
    }

    @Test("Token-dense sources degrade without partial colors")
    func tokenLimitDegradesToPlainText() {
        let result = highlighter.highlight(
            "let first = 1; let second = 2",
            language: .swift,
            maximumTokenCount: 2
        )
        #expect(result.didExceedTokenLimit)
        #expect(!result.wasCancelled)
        #expect(result.tokens.isEmpty)
        #expect(!FilePreviewSyntaxHighlightPolicy().accepts(result))
    }

    @Test("Swift keywords, types, strings, numbers, calls, and comments are classified")
    func swiftBasics() {
        let source = "let count: Int = call(42, \"hi\") // greeting"
        let classified = classifiedTokens(in: source, language: .swift)
        #expect(classified.contains(ClassifiedToken(text: "let", kind: .keyword)))
        #expect(classified.contains(ClassifiedToken(text: "Int", kind: .type)))
        #expect(classified.contains(ClassifiedToken(text: "call", kind: .function)))
        #expect(classified.contains(ClassifiedToken(text: "42", kind: .number)))
        #expect(classified.contains(ClassifiedToken(text: "\"hi\"", kind: .string)))
        #expect(classified.contains(ClassifiedToken(text: "// greeting", kind: .comment)))
    }

    @Test("SQL identifiers are matched case-insensitively")
    func sqlKeywordsAreCaseInsensitive() {
        let classified = classifiedTokens(
            in: "SELECT id FROM users WHERE active = TRUE",
            language: .sql
        )
        for keyword in ["SELECT", "FROM", "WHERE"] {
            #expect(classified.contains(ClassifiedToken(text: keyword, kind: .keyword)))
        }
    }

    @Test("Objective-C Foundation and Core Graphics names are types")
    func objectiveCTypes() {
        let classified = classifiedTokens(
            in: "NSString *name; CGRect frame; NSObject *owner;",
            language: .objc
        )
        for type in ["NSString", "CGRect", "NSObject"] {
            #expect(classified.contains(ClassifiedToken(text: type, kind: .type)))
        }
    }

    @Test("Rust lifetimes are not mistaken for strings")
    func rustLifetimesAreNotStrings() {
        let source = "fn choose<'a>(value: &'a str) -> &'a str { \"ok\" }"
        let strings = classifiedTokens(in: source, language: .rust)
            .filter { $0.kind == .string }
        #expect(strings == [ClassifiedToken(text: "\"ok\"", kind: .string)])
    }

    @Test("Python triple-quoted strings span lines")
    func pythonTripleQuotedStringsSpanLines() {
        let source = "value = \"\"\"first\nsecond\"\"\"\nreturn value"
        let strings = classifiedTokens(in: source, language: .python)
            .filter { $0.kind == .string }
        #expect(strings == [ClassifiedToken(text: "\"\"\"first\nsecond\"\"\"", kind: .string)])
    }

    @Test("JavaScript and Go backticks span lines")
    func backtickStringsSpanLines() {
        for language in [FilePreviewSyntaxLanguage.javascript, .typescript, .go] {
            let source = "const value = `first\nsecond`"
            let strings = classifiedTokens(in: source, language: language)
                .filter { $0.kind == .string }
            #expect(strings == [ClassifiedToken(text: "`first\nsecond`", kind: .string)])
        }
    }

    @Test("UTF-16 token ranges remain valid around emoji")
    func tokenRangesUseUTF16Offsets() {
        let source = "let value = \"🚀 launch\" // 🎉 done"
        let sourceLength = (source as NSString).length
        let result = highlighted(source, language: .swift)
        for token in result.tokens {
            #expect(token.utf16Range.lowerBound >= 0)
            #expect(token.utf16Range.upperBound <= sourceLength)
        }
        #expect(
            classifiedTokens(in: source, language: .swift)
                .contains(ClassifiedToken(text: "\"🚀 launch\"", kind: .string))
        )
    }

    @Test("Foreground luminance selects light and dark palettes")
    func appearanceAndPaletteFollowForeground() {
        let appearanceResolver = FilePreviewSyntaxAppearanceResolver()
        #expect(
            appearanceResolver.appearance(
                forForegroundRed: 1,
                green: 1,
                blue: 1
            ) == .dark
        )
        #expect(
            appearanceResolver.appearance(
                forForegroundRed: 0,
                green: 0,
                blue: 0
            ) == .light
        )
        #expect(
            appearanceResolver.appearance(
                forForegroundRed: 0.5,
                green: 0.5,
                blue: 0.5
            ) == .light
        )

        let palettes = FilePreviewSyntaxPaletteCatalog()
        for kind in FilePreviewSyntaxTokenKind.allCases {
            #expect(
                palettes.palette(for: .light).color(for: kind)
                    != palettes.palette(for: .dark).color(for: kind)
            )
        }
    }

    @Test("Cancelled work returns no partial colors")
    func cancellationDegradesToPlainText() async {
        let result = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await highlighter.highlightOffMain(
                String(repeating: "let value = 1\n", count: 10_000),
                language: .swift,
                maximumTokenCount: 100_000
            )
        }.value
        #expect(result.wasCancelled)
        #expect(result.tokens.isEmpty)
    }

    private func highlighted(
        _ source: String,
        language: FilePreviewSyntaxLanguage
    ) -> FilePreviewSyntaxHighlightResult {
        highlighter.highlight(source, language: language, maximumTokenCount: 100_000)
    }

    private func classifiedTokens(
        in source: String,
        language: FilePreviewSyntaxLanguage
    ) -> [ClassifiedToken] {
        highlighted(source, language: language).tokens.map { token in
            let range = NSRange(
                location: token.utf16Range.lowerBound,
                length: token.utf16Range.count
            )
            return ClassifiedToken(
                text: (source as NSString).substring(with: range),
                kind: token.kind
            )
        }
    }
}

private struct ClassifiedToken: Equatable {
    let text: String
    let kind: FilePreviewSyntaxTokenKind
}
