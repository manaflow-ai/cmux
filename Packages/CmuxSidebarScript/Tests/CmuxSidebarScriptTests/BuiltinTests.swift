import Testing
@testable import CmuxSidebarScript

@Suite struct BuiltinTests {
    @Test func stringBuilding() throws {
        #expect(try run("(str \"#\" 42)") == .string("#42"))
        #expect(try run("(join \", \" (list 1 2 3))") == .string("1, 2, 3"))
        #expect(try run("(upper \"abc\")") == .string("ABC"))
        #expect(try run("(substring \"hello\" 1 3)") == .string("el"))
    }

    @Test func stringPredicates() throws {
        #expect(try run("(starts-with? \"feature/x\" \"feature/\")") == .bool(true))
        #expect(try run("(includes? \"abc\" \"b\")") == .bool(true))
    }

    @Test func listOps() throws {
        #expect(try run("(count (list 1 2 3))") == .int(3))
        #expect(try run("(first (list 7 8))") == .int(7))
        #expect(try run("(rest (list 7 8 9))") == .list([.int(8), .int(9)]))
        #expect(try run("(append (list 1) (list 2 3))") == .list([.int(1), .int(2), .int(3)]))
        #expect(try run("(empty? (list))") == .bool(true))
        #expect(try run("(range 3)") == .list([.int(0), .int(1), .int(2)]))
    }

    @Test func records() throws {
        #expect(try run("(get (record :a 1 :b 2) :b)") == .int(2))
        #expect(try run("(get (record :a 1) :missing 9)") == .int(9))
        #expect(try run("(has? (record :a 1) :a)") == .bool(true))
        #expect(try run("(get (assoc (record :a 1) :a 5) :a)") == .int(5))
    }

    @Test func getOnNilIsSafe() throws {
        #expect(try run("(get nil :anything)") == .null)
        #expect(try run("(get nil :anything 3)") == .int(3))
    }
}
