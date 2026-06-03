import Testing
@testable import CmuxSwiftRender

@Suite struct SwiftViewInterpreterTests {
    let interp = SwiftViewInterpreter()

    @Test func parsesNestedStackWithChildrenAndSpacing() {
        let node = interp.evaluate("""
        VStack(spacing: 8) {
            Text("hi").font(.title)
            Text("bye")
        }
        """)
        #expect(node?.kind == .vstack)
        #expect(node?.spacing == 8)
        #expect(node?.children.count == 2)
        #expect(node?.children.first?.kind == .text)
        #expect(node?.children.first?.text == "hi")
        #expect(node?.children.first?.modifiers.first?.name == "font")
    }

    @Test func reorderableCapturesRowsItemIdsAndSpec() {
        let ws = SwiftValue.array([
            .object(["id": .string("w1"), "title": .string("A")]),
            .object(["id": .string("w2"), "title": .string("B")]),
        ])
        let node = interp.evaluate("""
        Reorderable(workspaces, move: "workspace.reorder") { w in
            Text(w.title)
        }
        """, state: ["workspaces": ws])
        #expect(node?.kind == .reorderable)
        #expect(node?.children.map(\.text) == ["A", "B"])
        #expect(node?.reorder?.method == "workspace.reorder")
        #expect(node?.reorder?.idParam == "workspace_id")
        #expect(node?.reorder?.itemIds == ["w1", "w2"])
    }

    @Test func parsesHSplitViewColumns() {
        let node = interp.evaluate("""
        HSplitView {
            VStack { Text("left") }
            VStack { Text("right") }
        }
        """)
        #expect(node?.kind == .hsplit)
        #expect(node?.children.count == 2)
        #expect(node?.children.first?.kind == .vstack)
        #expect(node?.children.last?.children.first?.text == "right")
    }

    @Test func parsesShapesAndLabeledFrameAndBackground() {
        let node = interp.evaluate("""
        HStack {
            RoundedRectangle(cornerRadius: 4).fill("#FF8800").frame(width: 40, height: 6)
            Text("pill").padding(4).background("#222222").cornerRadius(6)
            Spacer().frame(maxWidth: .infinity)
        }
        """)
        let bar = node?.children.first
        #expect(bar?.kind == .roundedRectangle)
        #expect(bar?.cornerRadius == 4)
        // .fill captured as a modifier with the hex value (quotes stripped at capture)
        #expect(bar?.modifiers.first(where: { $0.name == "fill" })?.firstValue == "#FF8800")
        // .frame keeps labeled args
        let frame = bar?.modifiers.first(where: { $0.name == "frame" })
        #expect(frame?.value("width") == "40")
        #expect(frame?.value("height") == "6")
        let spacerFrame = node?.children.last?.modifiers.first(where: { $0.name == "frame" })
        #expect(spacerFrame?.value("maxWidth") == ".infinity")
    }

    @Test func parsesImageSystemName() {
        let node = interp.evaluate("""
        HStack { Image(systemName: "folder.fill"); Text("Docs") }
        """)
        #expect(node?.children.first?.kind == .image)
        #expect(node?.children.first?.systemName == "folder.fill")
    }

    @Test func parsesTextLiteral() {
        let node = interp.evaluate(#"Text("hello world")"#)
        #expect(node?.kind == .text)
        #expect(node?.text == "hello world")
    }

    @Test func parsesButtonTitle() {
        let node = interp.evaluate(#"Button("Tap me") { }"#)
        #expect(node?.kind == .button)
        #expect(node?.text == "Tap me")
    }

    @Test func parsesHStackWithLeafPrimitives() {
        let node = interp.evaluate("""
        HStack {
            Spacer()
            Divider()
        }
        """)
        #expect(node?.kind == .hstack)
        #expect(node?.children.map(\.kind) == [.spacer, .divider])
    }

    @Test func returnsNilForUnsupported() {
        #expect(interp.evaluate("let x = 5") == nil)
    }

    @Test func interpretsForLoopWithInterpolation() {
        let node = interp.evaluate("""
        VStack {
            for i in 0..<3 {
                Text("Row \\(i)")
            }
        }
        """)
        #expect(node?.children.count == 3)
        #expect(node?.children.map(\.text) == ["Row 0", "Row 1", "Row 2"])
    }

    @Test func interpretsIfElseInsideLoop() {
        let node = interp.evaluate("""
        VStack {
            for i in 0..<3 {
                if i > 0 { Divider() }
                Text("\\(i)")
            }
        }
        """)
        // rows: Text(0), Divider, Text(1), Divider, Text(2)
        #expect(node?.children.map(\.kind) == [.text, .divider, .text, .divider, .text])
        #expect(node?.children.first?.text == "0")
    }

    @Test func interpretsLetBindingAndArithmeticInterpolation() {
        let node = interp.evaluate("""
        VStack {
            let name = "Items"
            Text(name)
            Text("total: \\(2 + 3 * 4)")
        }
        """)
        #expect(node?.children.map(\.text) == ["Items", "total: 14"])
    }

    @Test func readsStateFromEnvironment() {
        let node = interp.evaluate("""
        VStack {
            if showExtra {
                Text("extra: \\(count)")
            }
        }
        """, state: ["showExtra": .bool(true), "count": .int(7)])
        #expect(node?.children.map(\.text) == ["extra: 7"])
    }

    @Test func interpretsForEachOverArrayLiteral() {
        let node = interp.evaluate("""
        VStack {
            ForEach(["a", "b", "c"]) { name in
                Text(name)
            }
        }
        """)
        #expect(node?.children.map(\.text) == ["a", "b", "c"])
    }

    @Test func interpretsForEachOverRangeWithDollarParam() {
        let node = interp.evaluate("""
        VStack {
            ForEach(0..<2) { Text("n=\\($0)") }
        }
        """)
        #expect(node?.children.map(\.text) == ["n=0", "n=1"])
    }

    @Test func capturesButtonCmuxActionWithNamedParams() {
        let node = interp.evaluate("""
        VStack {
            for i in 0..<2 {
                Button("select \\(i)") { cmux("workspace.select", workspace_id: "ws-\\(i)") }
            }
        }
        """)
        #expect(node?.children.count == 2)
        #expect(node?.children.first?.action?.commands == [.cmux(method: "workspace.select", params: ["workspace_id": "ws-0"])])
        #expect(node?.children.last?.action?.commands == [.cmux(method: "workspace.select", params: ["workspace_id": "ws-1"])])
    }

    @Test func bindsWorkspacesFromDataContext() {
        let workspaces = SwiftValue.array([
            .object(["title": .string("Fall2023"), "selected": .bool(true)]),
            .object(["title": .string("feat-x"), "selected": .bool(false)]),
        ])
        let node = interp.evaluate("""
        VStack {
            Text("Workspaces: \\(workspaces.count)")
            ForEach(workspaces) { w in
                if w.selected { Text("▸ \\(w.title)") } else { Text(w.title) }
            }
        }
        """, state: ["workspaces": workspaces])
        #expect(node?.children.map(\.text) == ["Workspaces: 2", "▸ Fall2023", "feat-x"])
    }

    @Test func subscriptIndexingOverWorkspaces() {
        let workspaces = SwiftValue.array([
            .object(["title": .string("alpha"), "selected": .bool(false)]),
            .object(["title": .string("beta"), "selected": .bool(true)]),
        ])
        let node = interp.evaluate("""
        VStack {
            for i in 0..<workspaces.count {
                if workspaces[i].selected {
                    Text("▸ \\(workspaces[i].title)")
                } else {
                    Text(workspaces[i].title)
                }
            }
        }
        """, state: ["workspaces": workspaces])
        #expect(node?.children.map(\.text) == ["alpha", "▸ beta"])
    }

    @Test func labelFormButtonCapturesActionAndLabel() {
        let node = interp.evaluate("""
        VStack {
            Button(action: { cmux("workspace.select", workspace_id: "w-9") }) {
                HStack { Text("●"); Text("home") }
            }
        }
        """)
        let button = node?.children.first
        #expect(button?.kind == .button)
        #expect(button?.action?.commands == [.cmux(method: "workspace.select", params: ["workspace_id": "w-9"])])
        // label rendered as children (the HStack), not a string title
        #expect(button?.children.first?.kind == .hstack)
    }

    @Test func capturesOnTapGestureActionOnRichRow() {
        let node = interp.evaluate("""
        VStack {
            HStack { Text("●"); Text("home") }
                .onTapGesture { cmux("workspace.select", workspace_id: "abc-123") }
        }
        """)
        #expect(node?.children.first?.kind == .hstack)
        #expect(node?.children.first?.action?.commands == [.cmux(method: "workspace.select", params: ["workspace_id": "abc-123"])])
    }

    @Test func memberAccessOnObjectAndArray() {
        let data = SwiftValue.object(["name": .string("cmux"), "tabs": .array([.int(1), .int(2), .int(3)])])
        let node = interp.evaluate(#"VStack { Text("\(data.name): \(data.tabs.count)") }"#, state: ["data": data])
        #expect(node?.children.first?.text == "cmux: 3")
    }

    @Test func ternaryInInterpolationAndModifier() {
        let node = interp.evaluate("""
        VStack {
            for i in 0..<3 {
                Text(i == 1 ? "one" : "other")
            }
        }
        """)
        #expect(node?.children.map(\.text) == ["other", "one", "other"])
    }

    @Test func arrayFilterMapSortedFirstContains() {
        let ws = SwiftValue.array([
            .object(["title": .string("beta"), "selected": .bool(false), "n": .int(2)]),
            .object(["title": .string("alpha"), "selected": .bool(true), "n": .int(1)]),
        ])
        let node = interp.evaluate("""
        VStack {
            Text("selected: \\(workspaces.filter { $0.selected }.count)")
            Text("any: \\(workspaces.contains { $0.selected })")
            ForEach(workspaces.map { $0.title }.sorted()) { t in Text(t) }
            Text("first sel: \\(workspaces.first { $0.selected }.title)")
        }
        """, state: ["workspaces": ws])
        #expect(node?.children.map(\.text) == ["selected: 1", "any: true", "alpha", "beta", "first sel: alpha"])
    }

    @Test func stringMethods() {
        let node = interp.evaluate("""
        VStack {
            let name = "Feature-Branch"
            if name.hasPrefix("Feature") { Text(name.lowercased()) }
        }
        """)
        #expect(node?.children.first?.text == "feature-branch")
    }

    @Test func userValueFunctionWithIfReturn() {
        let node = interp.evaluate("""
        func statusColor(s) -> Color {
            if s == "passing" { return "#34C759" } else { return "#FF3B30" }
        }
        VStack {
            Text("a").foregroundColor(statusColor("passing"))
            Text("b").foregroundColor(statusColor("failing"))
        }
        """)
        #expect(node?.children.first?.modifiers.first(where: { $0.name == "foregroundColor" })?.firstValue == "#34C759")
        #expect(node?.children.last?.modifiers.first(where: { $0.name == "foregroundColor" })?.firstValue == "#FF3B30")
    }

    @Test func userViewFunctionHelper() {
        let node = interp.evaluate("""
        func row(title) -> some View {
            HStack { Text(title); Spacer() }
        }
        VStack {
            row("one")
            row("two")
        }
        """)
        #expect(node?.children.count == 2)
        #expect(node?.children.first?.kind == .hstack)
        #expect(node?.children.first?.children.first?.text == "one")
    }

    @Test func numberFormattedCurrencyAndReduce() {
        let items = SwiftValue.array([
            .object(["cost": .double(1.5)]),
            .object(["cost": .double(2.5)]),
        ])
        let node = interp.evaluate("""
        VStack {
            Text(items.reduce(0.0) { $0 + $1.cost }.formatted(.currency(code: "USD")))
        }
        """, state: ["items": items])
        #expect(node?.children.first?.text == "$4.00")
    }

    @Test func inclusiveRangeIterates() {
        let node = interp.evaluate("""
        HStack {
            for n in 1...3 { Text("\\(n)") }
        }
        """)
        #expect(node?.children.map(\.text) == ["1", "2", "3"])
    }

    @Test func integerDivisionByZeroDoesNotCrash() {
        // A zero divisor in interpreted source must fail soft (the division
        // yields nil and drops from the interpolation), never trap the process.
        let node = interp.evaluate("""
        VStack {
            Text("v=\\(10 / 0)")
            Text("m=\\(10 % 0)")
            Text("ok")
        }
        """)
        #expect(node?.kind == .vstack)
        // Soft-fail: the bad division/modulo yields nil, so the interpolation
        // segment drops and the literal prefix remains (not a crash, not a
        // garbage number).
        #expect(node?.children.map(\.text) == ["v=", "m=", "ok"])
    }

    @Test func logicalAndShortCircuitsPastOutOfBoundsRight() {
        // The right operand (out-of-bounds subscript) must not be forced when
        // the left is false; without short-circuiting the whole expression
        // returned nil and dropped the row.
        let xs = SwiftValue.array([.int(1)])
        let node = interp.evaluate("""
        VStack {
            if false && xs[5] == 1 { Text("bad") }
            Text("safe")
        }
        """, state: ["xs": xs])
        #expect(node?.children.map(\.text) == ["safe"])
    }

    @Test func sortedHonorsDescendingComparator() {
        let node = interp.evaluate("""
        HStack {
            ForEach([3, 1, 2].sorted { $0 > $1 }) { n in Text("\\(n)") }
        }
        """)
        #expect(node?.children.map(\.text) == ["3", "2", "1"])
    }

    @Test func viewHelperWithExplicitReturnRenders() {
        let node = interp.evaluate("""
        func badge(_ t: String) -> some View {
            return Text(t).font(.caption)
        }
        VStack {
            badge("hello")
        }
        """)
        #expect(node?.kind == .vstack)
        #expect(node?.children.first?.kind == .text)
        #expect(node?.children.first?.text == "hello")
    }

    @Test func currencyFormatHonorsCode() {
        // The euro code must not render a dollar sign.
        let node = interp.evaluate("""
        VStack {
            Text(4.0.formatted(.currency(code: "EUR")))
        }
        """)
        let text = node?.children.first?.text ?? ""
        #expect(!text.contains("$"))
        #expect(text.contains("4"))
    }
}
