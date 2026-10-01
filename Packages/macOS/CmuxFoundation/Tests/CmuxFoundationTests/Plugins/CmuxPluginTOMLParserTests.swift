import Testing
@testable import CmuxFoundation

@Suite("Plugin manifest TOML subset")
struct CmuxPluginTOMLParserTests {
    @Test("Parses tables, arrays of tables, and scalar values")
    func parsesManifestShapes() throws {
        let document = try CmuxPluginTOMLParser().parse(#"""
        # comment
        [plugin]
        name = "demo" # trailing comment
        kind = 'extension'
        count = 1_000

        [[actions]]
        id = "a"
        argv = [
          "./bin/a",   # first
          "--flag",
        ]
        palette = false

        [[actions]]
        id = "b"
        env = { key = "value", "quoted key" = "x" }
        """#)
        #expect(document["plugin"] == .table([
            "name": .string("demo"),
            "kind": .string("extension"),
            "count": .integer(1000),
        ]))
        guard case .array(let actions)? = document["actions"] else {
            Issue.record("actions should be an array of tables")
            return
        }
        #expect(actions.count == 2)
        #expect(actions[0] == .table([
            "id": .string("a"),
            "argv": .array([.string("./bin/a"), .string("--flag")]),
            "palette": .bool(false),
        ]))
        #expect(actions[1] == .table([
            "id": .string("b"),
            "env": .table(["key": .string("value"), "quoted key": .string("x")]),
        ]))
    }

    @Test("Decodes basic string escapes and keeps literal strings verbatim")
    func decodesStrings() throws {
        let document = try CmuxPluginTOMLParser().parse(#"""
        basic = "tab\tquote\"slash\\ \u00e9"
        literal = 'C:\path\n'
        """#)
        #expect(document["basic"] == .string("tab\tquote\"slash\\ \u{e9}"))
        #expect(document["literal"] == .string(#"C:\path\n"#))
    }

    @Test("Dotted keys create nested tables")
    func dottedKeys() throws {
        let document = try CmuxPluginTOMLParser().parse("""
        [a.b]
        c.d = true
        """)
        #expect(document["a"] == .table(["b": .table(["c": .table(["d": .bool(true)])])]))
    }

    @Test("Rejects duplicates, unsupported values, and trailing text with a line number")
    func rejectsInvalidInput() {
        let cases: [(String, Int)] = [
            ("a = 1\na = 2", 2),
            ("[t]\n[t]", 2),
            ("x = 1.5", 1),
            ("x = 1979-05-27", 1),
            ("x = \"\"\"multi\"\"\"", 1),
            ("x = \"unterminated", 1),
            ("x = 1 y = 2", 1),
            ("x = [1, 2", 1),
        ]
        for (text, line) in cases {
            do {
                _ = try CmuxPluginTOMLParser().parse(text)
                Issue.record("expected a parse error for \(text)")
            } catch let error as CmuxPluginTOMLError {
                #expect(error.line == line, "\(text)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }
}
