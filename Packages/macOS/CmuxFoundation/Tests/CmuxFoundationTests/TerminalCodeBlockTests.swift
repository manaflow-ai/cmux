import Foundation
import Testing
@testable import CmuxFoundation

/// Covers the pure half of terminal code blocks: finding fences, producing
/// the exact copy text, placing known blocks on a re-rendered screen, and the
/// Run safety rules.
@Suite("Terminal code blocks")
struct TerminalCodeBlockTests {
    // MARK: Fences and copy text

    @Test("Finds fenced blocks with info strings, keeping heredoc newlines intact")
    func findsFencesInMarkdown() throws {
        let markdown = """
        Run this:

        ```bash
        cat <<'EOF' > notes.txt
        first line
          indented line
        EOF
        ```

        and then `ls` inline.

        ~~~
        plain
        ~~~
        """
        let fences = TerminalCodeFenceParser().fences(inMarkdown: markdown)
        #expect(fences.count == 2)
        let first = try #require(fences.first)
        #expect(first.infoString == "bash")
        #expect(TerminalCodeBlockText().copyText(for: first) == "cat <<'EOF' > notes.txt\nfirst line\n  indented line\nEOF")
        #expect(fences[1].infoString == nil)
    }

    @Test("A closing fence must match the opening character and length")
    func closingFenceRules() {
        let lines = ["````md", "```", "inner", "```", "````"]
        let fences = TerminalCodeFenceParser().fences(inLines: lines)
        #expect(fences.count == 1)
        #expect(fences.first?.body == ["```", "inner", "```"])
    }

    @Test("Indented fences inside list items lose the list indentation")
    func indentedFence() {
        let markdown = "1. Build:\n\n   ```sh\n   make build\n     --verbose\n   ```\n"
        let fence = TerminalCodeFenceParser().fences(inMarkdown: markdown).first
        #expect(fence.map { TerminalCodeBlockText().copyText(for: $0) } == "make build\n  --verbose")
    }

    @Test("Unclosed screen fences are not offered")
    func unclosedScreenFence() {
        let rows = ["```bash", "echo half"]
        #expect(TerminalCodeFenceParser().fences(inLines: rows, includeUnclosed: false).isEmpty)
        #expect(TerminalCodeFenceParser().fences(inLines: rows, includeUnclosed: true).count == 1)
    }

    @Test("Copy text drops trailing spaces, blank edges and uniform prompts")
    func copyTextCleanup() {
        let body = ["", "$ cd repo   ", "$ make test\t", ""]
        let text = TerminalCodeBlockText().copyText(body: body, language: TerminalCodeBlockLanguage(infoString: "bash"))
        #expect(text == "cd repo\nmake test")
    }

    @Test("Mixed prompts in a shell block are kept verbatim")
    func mixedPromptsKept() {
        let body = ["$ echo hi", "echo there"]
        let text = TerminalCodeBlockText().copyText(body: body, language: TerminalCodeBlockLanguage(infoString: "sh"))
        #expect(text == "$ echo hi\necho there")
    }

    @Test("Console blocks keep only prompted commands and their continuations")
    func consoleSession() {
        let body = ["$ ls", "a.txt b.txt", "$ for f in *; do", "> echo $f", "> done", "a.txt"]
        let text = TerminalCodeBlockText().copyText(body: body, language: TerminalCodeBlockLanguage(infoString: "console"))
        #expect(text == "ls\nfor f in *; do\necho $f\ndone")
    }

    @Test("Shell tags are runnable; other languages are copy-only")
    func runnableClassification() {
        #expect(TerminalCodeBlock(text: "ls", language: "bash", origin: .screen).isRunnable)
        #expect(TerminalCodeBlock(text: "ls", language: "{.zsh}", origin: .screen).isRunnable)
        #expect(TerminalCodeBlock(text: "ls", language: "Shell title=x", origin: .screen).isRunnable)
        #expect(!TerminalCodeBlock(text: "let x = 1", language: "swift", origin: .screen).isRunnable)
        #expect(!TerminalCodeBlock(text: "ls", language: nil, origin: .screen).isRunnable)
        #expect(TerminalCodeBlock(text: "ls", language: nil, origin: .offered, runnable: true).isRunnable)
    }

    @Test("Block ids are content hashes, stable across instances")
    func stableIDs() {
        let a = TerminalCodeBlock(text: "make", language: "sh", label: "Build", origin: .offered)
        let b = TerminalCodeBlock(text: "make", language: "sh", origin: .screen)
        let c = TerminalCodeBlock(text: "make", language: "bash", origin: .screen)
        #expect(a.id == b.id)
        #expect(a.id != c.id)
    }

    // MARK: Locating on screen

    @Test("Locates a block that an agent TUI indented, decorated and hard-wrapped")
    func locatesWrappedBlock() {
        let block = [
            "gh workflow run ci.yml --repo example/project --ref feature/very-long-branch-name",
            "gh run list --limit 1",
        ]
        let rows = [
            "⏺ Push the branch, then run:",
            "",
            "  gh workflow run ci.yml --repo example/project --ref",
            "  feature/very-long-branch-name",
            "  gh run list --limit 1",
            "",
            "> ",
        ]
        #expect(TerminalCodeBlockScreenLocator().locate(block, in: rows) == 2...4)
    }

    @Test("Prefers the bottom-most copy of a repeated block")
    func prefersLatestMatch() {
        let rows = ["make", "other", "make"]
        #expect(TerminalCodeBlockScreenLocator().locate(["make"], in: rows) == 2...2)
    }

    @Test("A block cut off by the screen edge is not located")
    func partialBlockNotLocated() {
        let rows = ["line one", "line two"]
        #expect(TerminalCodeBlockScreenLocator().locate(["line one", "line two", "line three"], in: rows) == nil)
    }

    @Test("Offered blocks win overlapping rows over screen fences")
    func anchorPriority() {
        let rows = ["```bash", "deploy --prod", "```", "", "```", "note", "```"]
        let offered = TerminalCodeBlock(text: "deploy --prod", language: "bash", label: "Deploy", origin: .offered)
        let anchors = TerminalCodeBlockAnchorResolver().anchors(rows: rows, offered: [offered])
        #expect(anchors.count == 2)
        #expect(anchors[0].block.origin == .offered)
        #expect(anchors[0].rows == 1...1)
        #expect(anchors[1].block.origin == .screen)
        #expect(anchors[1].block.text == "note")
        #expect(TerminalCodeBlockAnchorResolver().anchor(atRow: 5, in: anchors)?.block.text == "note")
    }

    @Test("The pill sits on the blank row above a block, else on its first row")
    func pillRow() {
        let resolver = TerminalCodeBlockAnchorResolver()
        let block = TerminalCodeBlock(text: "make", origin: .screen)
        let rows = ["intro", "", "make", "make"]
        #expect(resolver.pillRow(for: TerminalCodeBlockAnchor(block: block, rows: 2...2), rows: rows) == 1)
        #expect(resolver.pillRow(for: TerminalCodeBlockAnchor(block: block, rows: 3...3), rows: rows) == 3)
        #expect(resolver.pillRow(for: TerminalCodeBlockAnchor(block: block, rows: 0...0), rows: rows) == 0)
    }

    // MARK: Transcripts

    @Test("Extracts fences from Claude Code and Codex assistant lines only")
    func transcriptExtraction() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let claude = try line([
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "Run:\n```bash\nnpm test\n```"]]],
        ])
        let sidechain = try line([
            "type": "assistant", "isSidechain": true,
            "message": ["content": [["type": "text", "text": "```bash\nrm -rf build\n```"]]],
        ])
        let user = try line([
            "type": "user",
            "message": ["content": "```bash\nwhoami\n```"],
        ])
        let codex = try line([
            "type": "response_item",
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "```sh\ncargo build\n```"]],
            ],
        ])
        let tail = Data(("{\"partial\n" + [claude, sidechain, user, codex].joined(separator: "\n")).utf8)
        let entries = AgentTranscriptCodeBlockExtractor().entries(fromJSONLTail: tail)
        #expect(entries.map(\.block.text) == ["npm test", "cargo build"])
        #expect(entries.allSatisfy { $0.block.origin == .transcript && $0.block.isRunnable })
    }

    // MARK: Run safety

    @Test("Run pastes without a trailing newline and strips control characters")
    func pasteSanitizing() {
        let policy = TerminalCodeBlockRunPolicy()
        #expect(policy.pasteText("make\n") == "make")
        #expect(policy.pasteText("a\r\nb") == "a\nb")
        #expect(policy.pasteText("echo \u{1B}[201~hi\u{07}") == "echo [201~hi")
        #expect(policy.pasteText("ls \u{202E}txt.exe\u{2066}x\u{2069}\u{2028}y") == "ls txt.exexy")
        #expect(policy.requiresReview("ls \u{202E}txt.exe"))
    }

    @Test("A multi-line command is pasted only while bracketed paste is on")
    func multilinePasteNeedsBracketedPaste() {
        let policy = TerminalCodeBlockRunPolicy()
        #expect(policy.mayPaste("make test", bracketedPasteActive: false))
        #expect(policy.mayPaste("make test\n", bracketedPasteActive: false))
        #expect(!policy.mayPaste("cd app\nmake", bracketedPasteActive: false))
        #expect(policy.mayPaste("cd app\nmake", bracketedPasteActive: true))
    }

    @Test("A soft-wrapped screen fence copies as one line")
    func softWrappedScreenFence() {
        // The terminal wrapped one long line across two rows; the unwrapped
        // viewport text has it whole.
        let rows = ["```bash", "gh workflow run ci.yml --repo example/app --re", "f main", "```"]
        let unwrapped = ["```bash", "gh workflow run ci.yml --repo example/app --ref main", "```"]
        let anchors = TerminalCodeBlockAnchorResolver().anchors(rows: rows, unwrappedLines: unwrapped)
        #expect(anchors.count == 1)
        #expect(anchors.first?.block.text == "gh workflow run ci.yml --repo example/app --ref main")
        #expect(anchors.first?.rows == 1...2)
    }

    @Test("Multi-line, long, or sanitized commands need review; short ones do not")
    func reviewRules() {
        let policy = TerminalCodeBlockRunPolicy(reviewCharacterThreshold: 20)
        #expect(!policy.requiresReview("ls -la"))
        #expect(!policy.requiresReview("ls -la\n"))
        #expect(policy.requiresReview("cd a\nmake"))
        #expect(policy.requiresReview(String(repeating: "x", count: 21)))
        #expect(policy.requiresReview("echo \u{1B}]52;c;x\u{07}"))
    }
}
