import Foundation
import Testing
@testable import CmuxNextBrowser

/// Random keyboard, mouse, IME, focus, page and async events against the
/// state machine and the real effect applier. `OmnibarSim.checkInvariants`
/// runs after every step: field text == model text, caret within bounds,
/// at most one highlighted row, suggestions closed when not editing, no
/// completion and no field write while composing.
@MainActor
@Suite struct OmnibarStressTests {
    /// SplitMix64: deterministic per seed.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func randomEventsKeepTheInvariants(seed: UInt64) {
        var random = Random(state: seed)
        let sim = OmnibarSim()
        let characters = Array("gith.ubcomexs/ -あ")
        let pages = [OmnibarSim.page, URL(string: "https://example.com/docs")!, URL(string: "about:blank")!, nil]
        for _ in 0..<3_000 where !sim.failed {
            let length = (sim.field.text as NSString).length
            switch Int.random(in: 0..<24, using: &random) {
            case 0: if !sim.field.editorActive { sim.focus(.keyboard) } else { sim.send(.key(.selectAll)) }
            case 1: if sim.field.editorActive { sim.blur() }
            case 2...6: if sim.field.editorActive { sim.type(String(characters.randomElement(using: &random)!), settle: Bool.random(using: &random)) }
            case 7: if sim.field.editorActive, sim.field.marked == nil { sim.backspace() }
            case 8:
                if sim.field.editorActive, sim.field.marked == nil {
                    let start = Int.random(in: 0...length, using: &random)
                    sim.moveSelection(to: NSRange(location: start, length: Int.random(in: 0...(length - start), using: &random)))
                }
            case 9:
                if sim.field.editorActive {
                    let marked = ["n", "に", "にほ", "にほん"].randomElement(using: &random)!
                    sim.compose(marked)
                }
            case 10: if sim.field.marked != nil { sim.commitComposition(["日本", "にほん", ""].randomElement(using: &random)!) }
            case 11: sim.key(.down)
            case 12: sim.key(.up)
            case 13: sim.key([.tab, .backTab].randomElement(using: &random)!)
            case 14: sim.key(.enter([.currentTab, .newBackgroundTab, .newForegroundTab].randomElement(using: &random)!))
            case 15: sim.key(.escape)
            case 16: sim.key([.undo, .redo].randomElement(using: &random)!)
            case 17:
                let start = Int.random(in: 0...length, using: &random)
                if sim.field.marked == nil {
                    sim.click(count: Int.random(in: 1...3, using: &random), selecting: NSRange(location: start, length: Int.random(in: 0...(length - start), using: &random)))
                }
            case 18:
                let rows = sim.popup.rows.count
                let row = rows == 0 || Bool.random(using: &random) ? nil : Int.random(in: 0..<rows, using: &random)
                sim.send(.rowHover(row: row, pointer: CGPoint(x: Int.random(in: 0...3, using: &random), y: Int.random(in: 0...3, using: &random))))
            case 19:
                let rows = max(sim.popup.rows.count, 1)
                sim.send(.rowClick(row: Int.random(in: 0..<rows, using: &random), .currentTab))
            case 20:
                // Answer the newest query, or deliver a stale one.
                if Bool.random(using: &random) || sim.queries.count < 2 {
                    sim.answer()
                } else {
                    let stale = sim.queries.removeFirst()
                    sim.send(.suggestions(generation: stale.generation, rows: sim.rows(for: stale.text)))
                }
            case 21: sim.send(.pageURLChanged(pages.randomElement(using: &random)!))
            case 22: if sim.field.editorActive, sim.field.marked == nil { sim.paste("a\nb") }
            default: sim.send([.searchEngineChanged, .popupScroll, .pasteAndGo("example.com")].randomElement(using: &random)!)
            }
        }
    }
}
