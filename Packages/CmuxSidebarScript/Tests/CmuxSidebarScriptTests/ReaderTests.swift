import Testing
@testable import CmuxSidebarScript

@Suite struct ReaderTests {
    @Test func readsScalars() throws {
        #expect(try Reader().read("42") == [.int(42)])
        #expect(try Reader().read("-7") == [.int(-7)])
        #expect(try Reader().read("3.5") == [.double(3.5)])
        #expect(try Reader().read("\"hi\"") == [.string("hi")])
        #expect(try Reader().read("true false nil") == [.bool(true), .bool(false), .null])
        #expect(try Reader().read(":title") == [.keyword("title")])
        #expect(try Reader().read("foo") == [.symbol("foo")])
    }

    @Test func readsNestedLists() throws {
        let forms = try Reader().read("(a (b c) 1)")
        #expect(forms == [.list([.symbol("a"), .list([.symbol("b"), .symbol("c")]), .int(1)])])
    }

    @Test func bracketsAreLists() throws {
        #expect(try Reader().read("[1 2]") == [.list([.int(1), .int(2)])])
    }

    @Test func quoteSugarExpands() throws {
        #expect(try Reader().read("'x") == [.list([.symbol("quote"), .symbol("x")])])
    }

    @Test func stringEscapes() throws {
        #expect(try Reader().read("\"a\\nb\\t\\\"c\\\"\"") == [.string("a\nb\t\"c\"")])
    }

    @Test func lineCommentsAndCommasIgnored() throws {
        let forms = try Reader().read("""
        ; leading comment
        (a, b) ; trailing
        """)
        #expect(forms == [.list([.symbol("a"), .symbol("b")])])
    }

    @Test func unterminatedStringThrows() {
        #expect(throws: LispError.self) { try Reader().read("\"oops") }
    }

    @Test func unclosedListThrows() {
        #expect(throws: LispError.self) { try Reader().read("(a b") }
    }
}
