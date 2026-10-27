import CmuxNextActions
import CmuxNextActionsTestSupport
import Testing

/// A compiled `when` clause (p04-input-055) answers what the interpreter answers: on every clause
/// of the shipped binding table and on 1000 fuzzed clauses, each against many contexts.
@MainActor @Suite struct CompiledWhenTests {
    static func agree(_ clause: WhenClause?, _ context: KeyContext) -> Bool {
        CompiledWhen(clause).evaluate(CompiledWhen.Input(context)) == (clause?.evaluate(context) ?? true)
    }

    @Test func catalogClausesAgreeWithTheInterpreter() {
        let table = KeyBindingTable.shippedCatalog()
        let clauses = Set((table.entries + table.removed + table.claimedByGhostty).compactMap(\.when))
        #expect(clauses.count > 10, "the shipped table has scoped entries")
        var fuzz = WhenFuzz(seed: 0x5EED_0055, clauses: Array(clauses))
        let contexts = (0..<400).map { _ in fuzz.context() } + WhenFuzz.namedContexts
        for clause in clauses {
            let disagreeing = contexts.filter { !Self.agree(clause, $0) }
            #expect(disagreeing.isEmpty, "\(clause.text) disagrees in \(disagreeing.count) contexts, first \(disagreeing.first?.values ?? [:])")
        }
    }

    @Test func fuzzedClausesAgreeWithTheInterpreter() {
        var fuzz = WhenFuzz(seed: 0xC0FF_EE55)
        var failures = 0
        for _ in 0..<1000 {
            let clause = fuzz.clause(depth: 4)
            for _ in 0..<64 {
                let context = fuzz.context()
                if !Self.agree(clause, context) {
                    failures += 1
                    Issue.record("\(clause) disagrees in \(context.values)")
                    break
                }
            }
            if failures > 5 { break }
        }
    }

    /// The legacy bits a catalog action requires compile to masks: no dictionary lookup.
    @Test func requiredContextCompilesToMasks() {
        for descriptor in ActionCatalog.all {
            let compiled = CompiledWhen(WhenClause.requiring(descriptor.requires))
            #expect(compiled.usesOnlyBits, "\(descriptor.id)")
        }
    }

    @Test func shapes() {
        let terminal = WhenClause.has("terminalFocused"), browser = WhenClause.has("browserFocused")
        #expect(CompiledWhen(nil) == .always)
        #expect(CompiledWhen(.and([terminal, .not(browser), .not(.not(.has("signedIn")))])).usesOnlyBits)
        #expect(CompiledWhen(.not(.or([terminal, browser]))).usesOnlyBits)
        #expect(CompiledWhen(.or([terminal, .and([browser, .not(terminal)])])).usesOnlyBits)
        #expect(CompiledWhen(.and([terminal, .not(terminal)])) == CompiledWhen(.constant(false)))
        #expect(CompiledWhen(.or([terminal, .not(terminal)])) != CompiledWhen(.constant(false)))
        #expect(CompiledWhen(.and([])) == .always)
        #expect(CompiledWhen(.or([])) == CompiledWhen(.constant(false)))
        #expect(!CompiledWhen(.equals(KeyContext.surfaceKind, .string("terminal"))).usesOnlyBits)
        #expect(!CompiledWhen(.has(KeyContext.topPage)).usesOnlyBits)
    }

    /// A bit test reads truthiness, as `has` does: "", 0, false and [] do not set the bit.
    @Test(arguments: [KeyContextValue.bool(false), .string(""), .number(0), .strings([]),
                      .bool(true), .string("x"), .number(2), .strings(["a"])])
    func bitTestsReadTruthiness(value: KeyContextValue) {
        let context = KeyContext(["terminalFocused": value])
        for clause in [WhenClause.has("terminalFocused"), .not(.has("terminalFocused")),
                       .and([.has("terminalFocused"), .not(.has("browserFocused"))])] {
            #expect(Self.agree(clause, context), "\(clause.text) with \(value)")
        }
    }
}
