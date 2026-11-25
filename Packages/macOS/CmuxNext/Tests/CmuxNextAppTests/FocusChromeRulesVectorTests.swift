import CmuxNextFocus
import Foundation
import Testing

/// Replays schemas/focus-chrome-rules/vectors.json through ``BrowserFocusModeEscapeExit`` and
/// ``WorkContextTrail``, which call the Rust rules (`focus_escape_exit`, `focus_work_context`,
/// cmux-focus-core) over the app FFI. The vectors were written from the Swift rules before they
/// moved; cmux-layout-reducer-ffi's `focus_chrome_rules` replays the same file, so this proves the
/// boundary in both directions.
struct FocusChromeRulesVectorTests {
    struct Key: Decodable {
        var isPlainEscape: Bool
        var isRepeat: Bool
        var timestamp: Double
        var focusModeTab: String?
    }

    struct EscapeStep: Decodable {
        var key: Key?
        var outcome: String
        var tab: String?
        var armedTab: String?
    }

    struct Target: Decodable {
        var current: WorkContextTrail.Entry?
        var workspace: String?
        var window: String?
        var workspaceHasWork: Bool
        var kinds: [WorkContextTrail.Kind]
    }

    struct TrailStep: Decodable {
        var record: WorkContextTrail.Entry?
        var forget: String?
        var trail: [String]?
        var candidates: Target?
        var reads: [String]?
    }

    struct Case<Step: Decodable>: Decodable {
        var name: String
        var steps: [Step]
    }

    struct Vectors: Decodable {
        var v: Int
        var escapeExit: [Case<EscapeStep>]
        var workContext: [Case<TrailStep>]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextAppTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/focus-chrome-rules/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    static func name(_ outcome: BrowserFocusModeEscapeExit.Outcome) -> (String, String?) {
        switch outcome {
        case .pass: ("pass", nil)
        case .forwardToPage: ("forwardToPage", nil)
        case .exit(let tab): ("exit", tab)
        case .consume: ("consume", nil)
        }
    }

    @Test func everyEscapeExitVectorAnswersAsTheSwiftRuleDid() throws {
        let vectors = try Self.vectors()
        #expect(vectors.v == 1)
        #expect(vectors.escapeExit.count > 40)
        for vector in vectors.escapeExit {
            var gesture = BrowserFocusModeEscapeExit()
            for (index, step) in vector.steps.enumerated() {
                let outcome: BrowserFocusModeEscapeExit.Outcome
                if let key = step.key {
                    outcome = gesture.handle(isPlainEscape: key.isPlainEscape, isRepeat: key.isRepeat, timestamp: key.timestamp,
                                             focusModeTab: key.focusModeTab)
                } else {
                    gesture.reset()
                    outcome = .pass
                }
                let (got, tab) = Self.name(outcome)
                #expect(got == step.outcome, "\(vector.name) step \(index)")
                #expect(tab == step.tab, "\(vector.name) step \(index)")
                #expect(gesture.armedTab == step.armedTab, "\(vector.name) step \(index)")
            }
        }
    }

    @Test func everyWorkContextVectorReadsAsTheSwiftRuleDid() throws {
        let vectors = try Self.vectors()
        #expect(vectors.workContext.count > 40)
        for vector in vectors.workContext {
            var trail = WorkContextTrail()
            for (index, step) in vector.steps.enumerated() {
                if let target = step.candidates {
                    // Every candidate read, in order: a value that is never live reads them all.
                    var reads: [String] = []
                    let found: String? = trail.resolve(current: target.current, workspace: target.workspace, window: target.window,
                                                        workspaceHasWork: target.workspaceHasWork, kinds: Set(target.kinds)) { entry in
                        reads.append(entry.tab)
                        return nil
                    }
                    #expect(found == nil)
                    #expect(reads == step.reads, "\(vector.name) step \(index)")
                    continue
                }
                if let entry = step.record { trail.record(entry) }
                if let tab = step.forget { trail.forget(tab: tab) }
                #expect(trail.entries.map(\.tab) == step.trail, "\(vector.name) step \(index)")
            }
        }
    }
}
