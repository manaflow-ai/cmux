import Foundation
import Testing
@testable import CmuxSettings

@Suite("ShortcutWhenClause")
struct ShortcutWhenClauseTests {
    private func state(browser: Bool = false, markdown: Bool = false, sidebar: Bool = false) -> ShortcutFocusState {
        ShortcutFocusState(browser: browser, markdown: markdown, sidebar: sidebar)
    }

    /// A context with one of each value kind for evaluation tests.
    private func sampleContext() -> ShortcutContext {
        var context = ShortcutContext()
        context.setBool("commandPaletteVisible", true)
        context.setString("sidebarMode", "find")
        context.setInt("paneCount", 2)
        return context
    }

    // MARK: - Backwards-compatible parsing (must produce identical trees)

    @Test func parsesNegatedAtom() {
        #expect(ShortcutWhenClause.parse("!sidebarFocus") == .not(.atom(.sidebarFocus)))
        #expect(ShortcutWhenClause.parse("  sidebarFocus ") == .atom(.sidebarFocus))
    }

    @Test func parsesAndOrWithPrecedence() {
        // && binds tighter than ||: "a || b && c" == "a || (b && c)".
        #expect(
            ShortcutWhenClause.parse("terminalFocus || browserFocus && markdownFocus")
                == .or(.atom(.terminalFocus), .and(.atom(.browserFocus), .atom(.markdownFocus)))
        )
        #expect(
            ShortcutWhenClause.parse("(terminalFocus || browserFocus) && !sidebarFocus")
                == .and(.or(.atom(.terminalFocus), .atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        )
    }

    @Test func emptyClauseParsesToAlways() {
        #expect(ShortcutWhenClause.parse("") == .always)
        #expect(ShortcutWhenClause.parse("   ") == .always)
    }

    // MARK: - New key parsing (unknown key → .key, not nil)

    @Test func parsesNonFocusKeyAsKey() {
        #expect(ShortcutWhenClause.parse("commandPaletteVisible") == .key("commandPaletteVisible"))
        #expect(ShortcutWhenClause.parse("someUnknownKey") == .key("someUnknownKey"))
        #expect(ShortcutWhenClause.parse("!commandPaletteVisible") == .not(.key("commandPaletteVisible")))
    }

    // MARK: - Priority-aware collision (bindingsCollide)

    @Test func priorityResolvedPairsCoexist() {
        let sidebar = ShortcutWhenClause.atom(.sidebarFocus)
        // The pre-routed sidebar action owns the overlap; an always-on binding
        // keeps every other context — the factory Select Surface ⌃1…9 alongside
        // the sidebar's ⌃1…5.
        #expect(!ShortcutWhenClause.bindingsCollide(
            .always, lhsHasPriority: false, sidebar, rhsHasPriority: true))
        #expect(!ShortcutWhenClause.bindingsCollide(
            sidebar, lhsHasPriority: true, .always, rhsHasPriority: false))
    }

    @Test func fullyShadowedLoserStillCollides() {
        let sidebar = ShortcutWhenClause.atom(.sidebarFocus)
        // A binding scoped entirely inside the winner's context would never
        // fire, so the pair must still surface as a conflict.
        #expect(ShortcutWhenClause.bindingsCollide(
            sidebar, lhsHasPriority: false, sidebar, rhsHasPriority: true))
    }

    @Test func equalPrioritySidesFallBackToPlainOverlap() throws {
        let sidebar = ShortcutWhenClause.atom(.sidebarFocus)
        // Two pre-routed sidebar actions on one stroke are a real conflict —
        // both live in the same prioritized context.
        #expect(ShortcutWhenClause.bindingsCollide(
            sidebar, lhsHasPriority: true, sidebar, rhsHasPriority: true))
        // Disjoint clauses coexist regardless of priority flags.
        let workspace = try #require(ShortcutWhenClause.parse("!sidebarFocus"))
        #expect(!ShortcutWhenClause.bindingsCollide(
            workspace, lhsHasPriority: false, sidebar, rhsHasPriority: true))
        #expect(!ShortcutWhenClause.bindingsCollide(
            workspace, lhsHasPriority: false, sidebar, rhsHasPriority: false))
        // Two unprioritized always-on bindings still collide.
        #expect(ShortcutWhenClause.bindingsCollide(
            .always, lhsHasPriority: false, .always, rhsHasPriority: false))
    }

    // MARK: - Boolean literals (VS Code parity)

    @Test func parsesBareBooleanLiterals() {
        // `true` imposes no restriction; `false` never matches.
        #expect(ShortcutWhenClause.parse("true") == .always)
        #expect(ShortcutWhenClause.parse("false") == .not(.always))
        #expect(ShortcutWhenClause.parse("!false") == .not(.not(.always)))
        #expect(ShortcutWhenClause.parse("true && commandPaletteVisible")
            == .and(.always, .key("commandPaletteVisible")))
        let context = ShortcutContext()
        #expect(ShortcutWhenClause.parse("true")?.evaluate(context) == true)
        #expect(ShortcutWhenClause.parse("false")?.evaluate(context) == false)
    }

    @Test func foldsBooleanLiteralEqualityOntoTheKey() throws {
        // `k == true` ≡ `k`, `k == false` ≡ `!k`, inverted for `!=` — VS Code's
        // `ContextKeyExpr.has`/`not` normalization.
        #expect(ShortcutWhenClause.parse("commandPaletteVisible == true")
            == .key("commandPaletteVisible"))
        #expect(ShortcutWhenClause.parse("commandPaletteVisible == false")
            == .not(.key("commandPaletteVisible")))
        #expect(ShortcutWhenClause.parse("commandPaletteVisible != true")
            == .not(.key("commandPaletteVisible")))
        #expect(ShortcutWhenClause.parse("commandPaletteVisible != false")
            == .key("commandPaletteVisible"))
        // Quoted literals dequote before the fold, as in VS Code.
        #expect(ShortcutWhenClause.parse("commandPaletteVisible == 'true'")
            == .key("commandPaletteVisible"))
        // A focus atom keeps its `.atom` form so conflict detection stays exact.
        #expect(ShortcutWhenClause.parse("sidebarFocus == true") == .atom(.sidebarFocus))
        #expect(ShortcutWhenClause.parse("sidebarFocus == false") == .not(.atom(.sidebarFocus)))
        // An absent boolean key reads as false, so `== false` matches it.
        let context = ShortcutContext()
        #expect(try #require(ShortcutWhenClause.parse("missingKey == false")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("missingKey == true")).evaluate(context)))
    }

    // MARK: - Comparison parsing

    @Test func parsesComparisons() throws {
        #expect(ShortcutWhenClause.parse("paneCount > 1")
            == .compare(key: "paneCount", op: .greaterThan, operand: .int(1)))
        #expect(ShortcutWhenClause.parse("workspaceCount >= 2")
            == .compare(key: "workspaceCount", op: .greaterThanOrEqual, operand: .int(2)))
        #expect(ShortcutWhenClause.parse("paneCount < 3")
            == .compare(key: "paneCount", op: .lessThan, operand: .int(3)))
        #expect(ShortcutWhenClause.parse("paneCount <= 3")
            == .compare(key: "paneCount", op: .lessThanOrEqual, operand: .int(3)))
        #expect(ShortcutWhenClause.parse("sidebarMode == 'find'")
            == .compare(key: "sidebarMode", op: .equals, operand: .string("find")))
        // Bareword string operand (no quotes).
        #expect(ShortcutWhenClause.parse("sidebarMode == find")
            == .compare(key: "sidebarMode", op: .equals, operand: .string("find")))
        #expect(ShortcutWhenClause.parse("sidebarMode != 'files'")
            == .compare(key: "sidebarMode", op: .notEquals, operand: .string("files")))
    }

    @Test func parsesRegexAndListOperands() throws {
        let regex = try #require(ShortcutRegex(pattern: "fi.*"))
        #expect(ShortcutWhenClause.parse("sidebarMode =~ /fi.*/")
            == .compare(key: "sidebarMode", op: .matches, operand: .regex(regex)))
        #expect(ShortcutWhenClause.parse("sidebarMode in ['find', 'files']")
            == .compare(key: "sidebarMode", op: .inList, operand: .list([.string("find"), .string("files")])))
        #expect(ShortcutWhenClause.parse("paneCount in [1, 2, 3]")
            == .compare(key: "paneCount", op: .inList, operand: .list([.int(1), .int(2), .int(3)])))
    }

    @Test func comparisonBindsTighterThanAnd() {
        // "a && b > c" == "a && (b > c)".
        #expect(ShortcutWhenClause.parse("commandPaletteVisible && paneCount > 1")
            == .and(.key("commandPaletteVisible"), .compare(key: "paneCount", op: .greaterThan, operand: .int(1))))
        #expect(ShortcutWhenClause.parse("sidebarMode == 'find' || browserFocus")
            == .or(.compare(key: "sidebarMode", op: .equals, operand: .string("find")), .atom(.browserFocus)))
    }

    // MARK: - Malformed input still rejected (nil)

    @Test(arguments: [
        "sidebarFocus &&",
        "(sidebarFocus",
        "!",
        "paneCount >",                 // relational missing operand
        "paneCount == == 1",           // double operator
        "paneCount > 1 > 2",           // chained comparison
        "=~ /x/",                      // starts with operator
        "sidebarMode =~ 'notregex'",   // =~ requires a regex literal
        "sidebarMode =~ /[/",          // unterminated/uncompilable regex
        "paneCount < 'x'",             // relational requires a number
    ])
    func rejectsMalformedExpressions(_ raw: String) {
        #expect(ShortcutWhenClause.parse(raw) == nil)
    }

    // MARK: - Evaluation against a focus state (backwards-compatible overload)

    @Test func evaluatesAtomsAgainstFocusState() {
        #expect(ShortcutWhenClause.atom(.sidebarFocus).evaluate(state(sidebar: true)))
        #expect(!ShortcutWhenClause.atom(.sidebarFocus).evaluate(state(browser: true)))
        #expect(ShortcutWhenClause.atom(.terminalFocus).evaluate(state()))
        #expect(!ShortcutWhenClause.atom(.terminalFocus).evaluate(state(sidebar: true)))
    }

    @Test func workspaceDigitsExceptSidebar() throws {
        let clause = try #require(ShortcutWhenClause.parse("!sidebarFocus"))
        #expect(clause.evaluate(state()))
        #expect(clause.evaluate(state(browser: true)))
        #expect(!clause.evaluate(state(sidebar: true)))
    }

    // MARK: - Evaluation against a full context

    @Test func evaluatesBooleanKeys() {
        let context = sampleContext()
        #expect(ShortcutWhenClause.key("commandPaletteVisible").evaluate(context))
        #expect(!ShortcutWhenClause.key("absentKey").evaluate(context))
    }

    @Test func evaluatesIntComparisons() throws {
        let context = sampleContext() // paneCount == 2
        #expect(try #require(ShortcutWhenClause.parse("paneCount > 1")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("paneCount > 5")).evaluate(context)))
        #expect(try #require(ShortcutWhenClause.parse("paneCount >= 2")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("paneCount < 2")).evaluate(context)))
        #expect(try #require(ShortcutWhenClause.parse("paneCount == 2")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("paneCount != 2")).evaluate(context)))
        #expect(try #require(ShortcutWhenClause.parse("paneCount in [1, 2, 3]")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("paneCount in [3, 4]")).evaluate(context)))
    }

    @Test func evaluatesStringComparisons() throws {
        let context = sampleContext() // sidebarMode == "find"
        #expect(try #require(ShortcutWhenClause.parse("sidebarMode == 'find'")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("sidebarMode == 'files'")).evaluate(context)))
        #expect(try #require(ShortcutWhenClause.parse("sidebarMode != 'files'")).evaluate(context))
        #expect(try #require(ShortcutWhenClause.parse("sidebarMode =~ /^fi/")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("sidebarMode =~ /xyz/")).evaluate(context)))
        #expect(try #require(ShortcutWhenClause.parse("sidebarMode in ['find', 'files']")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("sidebarMode in ['files', 'feed']")).evaluate(context)))
    }

    @Test func absentAndWrongTypeKeysFollowVSCodeSemantics() throws {
        let context = sampleContext()
        // Absent key: == is false, != is true (undefined != value).
        #expect(!(try #require(ShortcutWhenClause.parse("missingInt == 5")).evaluate(context)))
        #expect(try #require(ShortcutWhenClause.parse("missingInt != 5")).evaluate(context))
        #expect(!(try #require(ShortcutWhenClause.parse("missingInt > 0")).evaluate(context)))
        // Wrong type: sidebarMode is a string, so an int comparison reads false.
        #expect(!(try #require(ShortcutWhenClause.parse("sidebarMode > 1")).evaluate(context)))
    }

    // MARK: - Conflict detection (canCoexist)

    @Test func canCoexistIsExactForFocusOnlyClauses() throws {
        let workspace = try #require(ShortcutWhenClause.parse("!sidebarFocus"))
        // ⌃1 = workspace (not sidebar) and ⌃1 = sidebar do NOT collide.
        #expect(!ShortcutWhenClause.canCoexist(workspace, .atom(.sidebarFocus)))
        // Two always-on bindings genuinely collide.
        #expect(ShortcutWhenClause.canCoexist(.always, .always))
        // Workspace-except-sidebar still overlaps a browser-scoped binding.
        #expect(ShortcutWhenClause.canCoexist(workspace, .atom(.browserFocus)))
    }

    @Test func canCoexistSeparatesNegatedKey() throws {
        let visible = try #require(ShortcutWhenClause.parse("commandPaletteVisible"))
        let hidden = try #require(ShortcutWhenClause.parse("!commandPaletteVisible"))
        #expect(!ShortcutWhenClause.canCoexist(visible, hidden))
    }

    @Test func canCoexistAliasesSharedComparisonTerms() throws {
        // The same comparison in both clauses must map to one free variable, so
        // they coexist (both true under paneCount == 1).
        let one = try #require(ShortcutWhenClause.parse("paneCount == 1"))
        #expect(ShortcutWhenClause.canCoexist(one, one))
        // A comparison and its negation never coexist (aliasing correctness).
        let notOne = try #require(ShortcutWhenClause.parse("!(paneCount == 1)"))
        #expect(!ShortcutWhenClause.canCoexist(one, notOne))
    }

    @Test func canCoexistConservativelyOverReportsExclusiveComparisons() throws {
        // paneCount == 1 and paneCount == 2 are mutually exclusive in reality, but
        // modeling each comparison independently over-reports coexistence (true) —
        // the harmless direction (a spurious conflict warning, never a hidden one).
        let one = try #require(ShortcutWhenClause.parse("paneCount == 1"))
        let two = try #require(ShortcutWhenClause.parse("paneCount == 2"))
        #expect(ShortcutWhenClause.canCoexist(one, two))
    }

    @Test func canCoexistFallsBackToConservativeTrueBeyondCap() {
        // 13 distinct boolean keys exceed the enumeration cap, so the result is a
        // conservative `true` even though these clauses are really exclusive.
        var allKeys: ShortcutWhenClause = .key("k0")
        for index in 1...12 {
            allKeys = .and(allKeys, .key("k\(index)"))
        }
        #expect(ShortcutWhenClause.canCoexist(allKeys, .not(.key("k0"))))
    }

    @Test func canCoexistMixesFocusAndContextTerms() throws {
        // Same focus + opposite context key → cannot coexist.
        let a = try #require(ShortcutWhenClause.parse("sidebarFocus && commandPaletteVisible"))
        let b = try #require(ShortcutWhenClause.parse("sidebarFocus && !commandPaletteVisible"))
        #expect(!ShortcutWhenClause.canCoexist(a, b))
        #expect(ShortcutWhenClause.canCoexist(a, a))
        // browser and markdown focus never co-occur (the one realizability
        // exclusion), so clauses gated on each cannot coexist even when they share
        // a context key.
        let browser = try #require(ShortcutWhenClause.parse("browserFocus && commandPaletteVisible"))
        let markdown = try #require(ShortcutWhenClause.parse("markdownFocus && commandPaletteVisible"))
        #expect(!ShortcutWhenClause.canCoexist(browser, markdown))
    }
}
