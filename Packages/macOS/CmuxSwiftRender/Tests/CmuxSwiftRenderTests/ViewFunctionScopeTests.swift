import Testing
@testable import CmuxSwiftRender

/// View-function control flow and file-scope bindings: an explicit `return`
/// exits the helper (even from inside `if`/`for`/`switch`), and file-scope
/// `let`s are visible inside user functions.
@Suite struct ViewFunctionScopeTests {
    let interp = SwiftViewInterpreter()

    @Test func returnExitsViewFunctionBeforeFallthrough() {
        let node = interp.evaluate("""
        func badge(_ w) -> some View {
            if w.unread == 0 { return AnyView(Text("EARLY")) }
            return AnyView(Text("FALLTHROUGH"))
        }
        VStack { badge(w) }
        """, state: [
            "w": .object(["unread": .int(0)]),
        ])
        #expect(node?.kind == .vstack)
        #expect(node?.children.map(\.text) == ["EARLY"])
    }

    @Test func returnInsideForLoopExitsViewFunction() {
        let node = interp.evaluate("""
        func pick(_ xs) -> some View {
            for x in xs {
                if x == "b" { return Text(x) }
            }
            return Text("none")
        }
        VStack { pick(items) }
        """, state: [
            "items": .array([.string("a"), .string("b"), .string("c")]),
        ])
        #expect(node?.kind == .vstack)
        #expect(node?.children.map(\.text) == ["b"])
    }

    @Test func returnInsideSwitchExitsViewFunction() {
        let node = interp.evaluate("""
        func label(_ k) -> some View {
            switch k {
            case "a": return Text("A")
            default: break
            }
            return Text("other")
        }
        VStack { label(k) }
        """, state: [
            "k": .string("a"),
        ])
        #expect(node?.kind == .vstack)
        #expect(node?.children.map(\.text) == ["A"])
    }

    @Test func topLevelLetIsVisibleInsideFunction() {
        let node = interp.evaluate("""
        let MARK = "X:"
        func label(_ v) -> String { return "\\(MARK)\\(v)" }
        VStack { Text(label(s)) }
        """, state: [
            "s": .string("a-b-c"),
        ])
        #expect(node?.kind == .vstack)
        #expect(node?.children.map(\.text) == ["X:a-b-c"])
    }
}
