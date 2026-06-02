import Testing
@testable import CmuxSidebarScript

@Suite struct EvaluatorTests {
    @Test func arithmetic() throws {
        #expect(try run("(+ 1 2 3)") == .number(6))
        #expect(try run("(- 10 3 2)") == .number(5))
        #expect(try run("(* 2 3 4)") == .number(24))
        #expect(try run("(/ 12 3 2)") == .number(2))
        #expect(try run("(- 5)") == .number(-5))
        #expect(try run("(mod 7 3)") == .number(1))
    }

    @Test func comparisonAndLogic() throws {
        #expect(try run("(< 1 2 3)") == .bool(true))
        #expect(try run("(< 1 3 2)") == .bool(false))
        #expect(try run("(= 2 2 2)") == .bool(true))
        #expect(try run("(and true 1 2)") == .int(2))
        #expect(try run("(or false nil 7)") == .int(7))
        #expect(try run("(not nil)") == .bool(true))
    }

    @Test func ifAndCond() throws {
        #expect(try run("(if true 1 2)") == .int(1))
        #expect(try run("(if nil 1 2)") == .int(2))
        #expect(try run("(if (> 1 2) 1)") == .null)
        #expect(try run("(cond (false 1) (true 2) (else 3))") == .int(2))
        #expect(try run("(cond (false 1) (else 3))") == .int(3))
    }

    @Test func whenUnless() throws {
        #expect(try run("(when true 1 2)") == .int(2))
        #expect(try run("(when false 1)") == .null)
        #expect(try run("(unless false 9)") == .int(9))
    }

    @Test func letBindsSequentially() throws {
        #expect(try run("(let ((a 2) (b (* a 3))) (+ a b))") == .number(8))
    }

    @Test func defineAndClosures() throws {
        #expect(try run("(def x 5) (* x x)") == .number(25))
        #expect(try run("(def (sq n) (* n n)) (sq 6)") == .number(36))
        #expect(try run("((fn (a b) (+ a b)) 3 4)") == .number(7))
    }

    @Test func restParameters() throws {
        #expect(try run("(def (f a & more) (count more)) (f 1 2 3 4)") == .int(3))
    }

    @Test func recursion() throws {
        let src = """
        (def (fact n) (if (<= n 1) 1 (* n (fact (- n 1)))))
        (fact 5)
        """
        #expect(try run(src) == .number(120))
    }

    @Test func higherOrder() throws {
        #expect(try run("(map (fn (x) (* x 2)) (list 1 2 3))")
            == .list([.number(2), .number(4), .number(6)]))
        #expect(try run("(filter (fn (x) (> x 1)) (list 0 1 2 3))")
            == .list([.int(2), .int(3)]))
        #expect(try run("(reduce + 0 (list 1 2 3 4))") == .number(10))
    }

    @Test func unboundSymbolThrows() {
        #expect(throws: LispError.self) { try run("nope") }
    }

    @Test func arityErrorThrows() {
        #expect(throws: LispError.self) { try run("(def (f a) a) (f 1 2)") }
    }

    @Test func infiniteRecursionIsBounded() {
        #expect(throws: LispError.self) {
            try run("(def (loop n) (loop (+ n 1))) (loop 0)")
        }
    }

    @Test func stepLimitStopsRunawayLoops() {
        // A tight non-recursive expansion that blows the step budget.
        let forms = try! Reader().read("(reduce + 0 (range 100))")
        let env = LispEnvironment()
        Builtins.install(into: env)
        Bridge.install(into: env)
        let ev = Evaluator(stepLimit: 5, depthLimit: 512)
        #expect(throws: LispError.self) {
            for f in forms { _ = try ev.eval(f, in: env) }
        }
    }
}
