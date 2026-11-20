import Foundation
import Testing
@testable import CmuxNextChiefMemory

/// The memory import flow's pure parts: what the CLI answers, the titles the person reads and the arguments
/// the app runs (a person can run the same `optchat-chief memory import-from` by hand).
@Suite struct ChiefMemoryImportTests {
    private let detected = Data("""
    {"sources":[
      {"source":"claude-code","kind":"claude-code","count":95,"bytes":187814733,"path":"/Users/me/.claude/projects"},
      {"source":"claude-memory","kind":"claude-memory","count":722,"bytes":1757797,"path":"/Users/me/.claude/projects"},
      {"source":"zip:/Users/me/Downloads/data-2026.zip","kind":"chatgpt-export","count":1,"bytes":900,"path":"/Users/me/Downloads/data-2026.zip"},
      {"source":"future","kind":"something-new","count":1,"bytes":1,"path":"/x"}
    ]}
    """.utf8)

    @Test func detectAnswerParsesAndSkipsKindsItDoesNotKnow() {
        let sources = MemorySource.parse(detected)
        #expect(sources.map(\.kind) == [.claudeCode, .claudeMemory, .chatgptExport])
        #expect(sources[0].count == 95)
        #expect(sources[2].source == "zip:/Users/me/Downloads/data-2026.zip")
        #expect(MemorySource.parse(Data("not json".utf8)).isEmpty)
        #expect(MemorySource.parse(Data()).isEmpty)
    }

    @Test func titlesNameTheSourceAndItsSize() {
        let sources = MemorySource.parse(detected)
        #expect(sources[0].title == "Claude Code conversations (95)")
        #expect(sources[1].title == "Claude Code memory notes (722)")
        #expect(sources[2].title == "ChatGPT export: data-2026.zip")
    }

    @Test func offerNamesTwoProductsAndSummarizesMore() throws {
        let sources = MemorySource.parse(detected)
        // Claude Code (twice: one product), ChatGPT: two names fit the row.
        let offer = try #require(MemorySource.offerTitle(sources, locale: Locale(identifier: "en_US")))
        #expect(offer == "Bring your memory from Claude Code and ChatGPT")
        let codex = MemorySource(source: "codex", kind: .codex, count: 3, bytes: 1, path: "/c")
        #expect(MemorySource.offerTitle(sources + [codex], locale: Locale(identifier: "en_US")) == "Bring your memory from other AI tools")
        #expect(MemorySource.offerTitle([]) == nil)
    }

    @Test func noTextCountsSteps() {
        let texts = [ChiefMemoryImportStrings.title, ChiefMemoryImportStrings.lead, ChiefMemoryImportStrings.safety,
                     ChiefMemoryImportStrings.restartNote, ChiefMemoryImportStrings.nothingFound, ChiefMemoryImportStrings.working,
                     ChiefMemoryImportStrings.done(3), ChiefMemoryImportStrings.offer("Codex"),
                     ChiefMemoryImportStrings.nothingNew, ChiefMemoryImportStrings.failed]
        for text in texts {
            #expect(text.range(of: #"\b\d+\s+steps?\b"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(text)")
            #expect(text.range(of: #"\bsteps?\s+\d+"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(text)")
        }
    }

    @Test func reportParsesAPlanAndAWrite() throws {
        let json = Data(#"{"batch":"b1","est_cost_usd":0.5,"plan":{"duplicate":2,"new":7,"secrets":1,"total":10,"source":"codex"},"to":"local","written":7}"#.utf8)
        let report = try #require(MemoryImportReport.parse(json))
        #expect(report.plan == .init(total: 10, new: 7, duplicate: 2, secrets: 1))
        #expect(report.written == 7)
        #expect(report.estCostUSD == 0.5)
        #expect(MemoryImportReport.parse(Data("nope".utf8)) == nil)
    }

    @Test func localImportStopsTheHostAndKeepsTheMuxHome() {
        let command = MemoryImportCommand(target: .local(muxHome: "/h/mux"))
        #expect(command.detect() == ["memory", "import-from", "detect", "--json", "--mux-home", "/h/mux"])
        // LAUNCH-NO-TCC-PROMPTS: only the person's own Import asks for the zips in ~/Downloads and ~/Desktop.
        #expect(!command.detect().contains("--exports"))
        #expect(command.detect(exports: true).contains("--exports"))
        #expect(command.dryRun("codex") == ["memory", "import-from", "codex", "dry-run", "--json", "--mux-home", "/h/mux"])
        let write = command.write("claude-code", batch: "b9")
        #expect(write.starts(with: ["memory", "import-from", "claude-code", "write", "--json", "--batch", "b9", "--max-cost", "20"]))
        #expect(write.contains("--stop-host"))
        #expect(command.undo().contains("--stop-host"))
    }

    @Test func cloudImportNeedsNoStoppedHostAndNeverPutsTheTokenOnTheCommandLine() {
        let command = MemoryImportCommand(target: .cloud(chief: "agent_1", tokenFile: "/tmp/t/session-token"))
        let write = command.write("zip:/x.zip", batch: "b1")
        #expect(write.contains("--to") && write.contains("cloud") && write.contains("agent_1"))
        #expect(!write.contains("--stop-host"))
        #expect(write.contains("--session-token-file"))
        #expect(!write.contains("--mux-home"))
        #expect(!write.joined(separator: " ").contains("Bearer"))
    }
}
