import CmuxTerminalRenderCore
import Foundation
import Testing

@Suite struct TerminalWorkloadTests {
    let generator = TerminalWorkloadGenerator()

    @Test func generatedWorkloadsAreDeterministic() throws {
        for workload in TerminalWorkload.generatedDefaults {
            let a = try #require(generator.script(workload, cols: 80, rows: 24))
            let b = try #require(generator.script(workload, cols: 80, rows: 24))
            #expect(a == b, "\(workload.id)")
            #expect(!a.chunks.isEmpty)
        }
    }

    @Test func seedChangesTheStream() throws {
        let a = try #require(TerminalWorkloadGenerator(seed: 1).script(.htop(frames: 3)))
        let b = try #require(TerminalWorkloadGenerator(seed: 2).script(.htop(frames: 3)))
        #expect(a.chunks != b.chunks)
    }

    @Test func floodHasExactSizeAndChunking() throws {
        let script = try #require(generator.script(.flood(bytes: 200_000)))
        #expect(script.totalBytes == 200_000)
        #expect(script.chunks.dropLast().allSatisfy { $0.count == generator.floodChunkBytes })
        #expect(script.chunks.count == Int((200_000.0 / Double(generator.floodChunkBytes)).rounded(.up)))
    }

    @Test func htopRedrawsTheWholeScreenEachFrame() throws {
        let script = try #require(generator.script(.htop(frames: 5), cols: 100, rows: 30))
        #expect(script.chunks.count == 5)
        for chunk in script.chunks {
            let text = String(decoding: chunk, as: UTF8.self)
            #expect(text.hasPrefix("\u{1B}[?25l\u{1B}[H"), "each frame homes the cursor")
            // header 4 + column titles 1 + rows - 6 process lines, each ending in a newline
            let newlines = text.components(separatedBy: "\r\n").count - 1
            let expected = 4 + 1 + (30 - 6)
            #expect(newlines == expected)
        }
    }

    @Test func vimUsesTheAlternateScreenAndAScrollRegion() throws {
        let script = try #require(generator.script(.vim(frames: 10), cols: 80, rows: 24))
        #expect(script.chunks.count == 11)
        let open = String(decoding: script.chunks[0], as: UTF8.self)
        #expect(open.hasPrefix("\u{1B}[?1049h"))
        #expect(open.contains("\u{1B}[1;23r"))
        let frame = String(decoding: script.chunks[1], as: UTF8.self)
        #expect(frame.contains("\u{1B}[23;1H\n"), "scrolls the region from its bottom line")
    }

    @Test func corpusIsNotGenerated() {
        #expect(generator.script(.corpus("styles")) == nil)
    }

    @Test func workloadIDsRoundTrip() {
        for workload in TerminalWorkload.generatedDefaults + [.corpus("shell-prompt")] {
            #expect(TerminalWorkload(id: workload.id) == workload)
        }
        #expect(TerminalWorkload(id: "corpus:") == nil)
        #expect(TerminalWorkload(id: "nope") == nil)
    }

    @Test func corpusScriptSplitsInChunks() throws {
        let entry = try #require(try TerminalCorpusManifest(decoding: Data(contentsOf: Fixtures.schemas.appendingPathComponent("manifest.json"))).case(named: "styles"))
        let bytes = try Data(contentsOf: Fixtures.schemas.appendingPathComponent(entry.file))
        let script = generator.script(corpus: entry, bytes: bytes)
        #expect(script.totalBytes == entry.bytes)
        #expect(script.cols == entry.cols && script.rows == entry.rows)
        #expect(script.chunks.reduce(Data(), +) == bytes)
    }
}
