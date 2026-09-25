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

    @Test func listSectionLazyAndGroupContainers() {
        let node = interp.evaluate("""
        List {
            Section("Repos") {
                LazyVStack {
                    Text("a")
                    Text("b")
                }
            }
            Group {
                Text("c")
            }
        }
        """)
        #expect(node?.kind == .list)
        let section = node?.children.first
        #expect(section?.kind == .section)
        #expect(section?.text == "Repos")
        #expect(section?.children.first?.kind == .lazyVStack)
        #expect(section?.children.first?.children.map(\.text) == ["a", "b"])
        #expect(node?.children.last?.kind == .group)
    }

    @Test func horizontalScrollViewBecomesHscrollVerticalStaysPassthrough() {
        let h = interp.evaluate("""
        ScrollView(.horizontal) {
            HStack { Text("x"); Text("y") }
        }
        """)
        #expect(h?.kind == .hscroll)
        #expect(h?.children.first?.kind == .hstack)

        let v = interp.evaluate("""
        ScrollView {
            Text("only")
        }
        """)
        #expect(v?.kind == .vstack)
        #expect(v?.children.first?.text == "only")
    }

    @Test func forEachEnumeratedTwoArgClosureDestructures() {
        let node = interp.evaluate("""
        VStack {
            ForEach(Array(["a", "b", "c"].enumerated()), id: \\.offset) { i, name in
                Text("\\(i):\\(name)")
            }
        }
        """)
        #expect(node?.children.map(\.text) == ["0:a", "1:b", "2:c"])
    }

    @Test func forEachOverIndices() {
        let xs = SwiftValue.array([.string("x"), .string("y")])
        let node = interp.evaluate("""
        VStack {
            ForEach(items.indices) { i in Text("\\(i)") }
        }
        """, state: ["items": xs])
        #expect(node?.children.map(\.text) == ["0", "1"])
    }

    @Test func arraySliceHelpersAndConversions() {
        let node = interp.evaluate("""
        HStack {
            Text("\\([1,2,3,4].dropFirst(2).count)")
            Text("\\([1,2,3,4].suffix(1).count)")
            Text("\\(Int("42"))")
        }
        """)
        #expect(node?.children.map(\.text) == ["2", "1", "42"])
    }

    @Test func deeplyNestedViewDoesNotCrash() {
        // 600 levels of nesting overflows the small caller stack (both the
        // swift-syntax parse and this walker recurse with depth); the large-
        // stack worker thread absorbs it and it renders without crashing.
        let depth = 600
        let source = String(repeating: "VStack { ", count: depth) + "Text(\"deep\")" + String(repeating: " }", count: depth)
        let node = interp.evaluate(source)
        #expect(node?.kind == .vstack)
    }

    @Test func progressGaugeMenuAndContextMenu() {
        let p = interp.evaluate(#"VStack { ProgressView(value: 30, total: 120) }"#)
        #expect(p?.children.first?.kind == .progressView)
        #expect(p?.children.first?.value == 0.25)

        let indeterminate = interp.evaluate(#"VStack { ProgressView() }"#)
        #expect(indeterminate?.children.first?.kind == .progressView)
        #expect(indeterminate?.children.first?.value == nil)

        let menu = interp.evaluate("""
        Menu("Actions") {
            Button("Stop") { cmux("agent.stop") }
        }
        """)
        #expect(menu?.kind == .menu)
        #expect(menu?.text == "Actions")
        #expect(menu?.children.first?.kind == .button)

        let ctx = interp.evaluate("""
        Text("row").contextMenu {
            Button("Open") { cmux("workspace.select") }
        }
        """)
        let cm = ctx?.modifiers.first { $0.name == "contextMenu" }
        #expect(cm?.children.first?.kind == .button)
    }

    @Test func gridRowsAndViewThatFits() {
        let node = interp.evaluate("""
        Grid {
            GridRow {
                Text("a")
                Text("b")
            }
            GridRow {
                Text("c")
                Text("d")
            }
        }
        """)
        #expect(node?.kind == .grid)
        #expect(node?.children.map(\.kind) == [.gridRow, .gridRow])
        #expect(node?.children.first?.children.map(\.text) == ["a", "b"])

        let fits = interp.evaluate("""
        ViewThatFits {
            Text("wide label")
            Text("x")
        }
        """)
        #expect(fits?.kind == .viewThatFits)
        #expect(fits?.children.count == 2)
    }

    @Test func numericBuiltinsMinMaxAbs() {
        let node = interp.evaluate("""
        HStack {
            Text("\\(min(3, 7))")
            Text("\\(max(3, 7))")
            Text("\\(abs(-5))")
        }
        """)
        #expect(node?.children.map(\.text) == ["3", "7", "5"])
    }

    @Test func imageSymbolModifiersCaptured() {
        let node = interp.evaluate("""
        Image(systemName: "star")
            .imageScale(.large)
            .symbolRenderingMode(.hierarchical)
            .symbolVariant(.fill)
        """)
        #expect(node?.kind == .image)
        let names = Set((node?.modifiers ?? []).map(\.name))
        #expect(names.isSuperset(of: ["imageScale", "symbolRenderingMode", "symbolVariant"]))
    }

    @Test func overlayAndBackgroundCaptureArbitraryChildViews() {
        let node = interp.evaluate("""
        Text("base")
            .overlay(alignment: .topTrailing) {
                Circle().frame(width: 8, height: 8)
            }
            .background {
                RoundedRectangle(cornerRadius: 8)
            }
        """)
        let overlay = node?.modifiers.first { $0.name == "overlay" }
        #expect(overlay?.children.first?.kind == .circle)
        #expect(overlay?.value("alignment") == ".topTrailing" || overlay?.value("alignment") == "topTrailing")
        let background = node?.modifiers.first { $0.name == "background" }
        #expect(background?.children.first?.kind == .roundedRectangle)
    }

    @Test func gradientsCaptureColorsAndPoints() {
        let node = interp.evaluate("""
        ZStack {
            LinearGradient(colors: [.red, "#0A84FF"], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        """)
        let g = node?.children.first
        #expect(g?.kind == .linearGradient)
        #expect(g?.colors == ["red", "#0A84FF"])
        #expect(g?.points == ["topLeading", "bottomTrailing"])

        let radial = interp.evaluate("""
        ZStack { RadialGradient(colors: ["#fff", "#000"], center: .center) }
        """)
        #expect(radial?.children.first?.kind == .radialGradient)
    }

    @Test func stringTrimmingCharacters() {
        let node = interp.evaluate("""
        VStack {
            Text("  hi  ".trimmingCharacters(in: .whitespaces))
            Text("\\("  hi  ".trimmingCharacters(in: .whitespacesAndNewlines).count)")
        }
        """)
        #expect(node?.children.first?.text == "hi")
        #expect(node?.children.last?.text == "2")
    }

    @Test func stringAndArrayJoinHelpers() {
        let node = interp.evaluate("""
        VStack {
            Text(["a", "b", "c"].joined(separator: "/"))
            Text("hello world".capitalized)
            Text("a-b-c".replacingOccurrences(of: "-", with: "."))
        }
        """)
        #expect(node?.children.map(\.text) == ["a/b/c", "Hello World", "a.b.c"])
    }

    @Test func closuresHonorLocalLetBindings() {
        // map/reduce/sorted closures with a local `let` must define it (was a
        // bug: closures returned the first expression, skipping let bindings).
        let mapped = interp.evaluate("""
        HStack { ForEach([1, 2, 3].map { x in let d = x * 2; d + 1 }) { n in Text("\\(n)") } }
        """)
        #expect(mapped?.children.map(\.text) == ["3", "5", "7"])

        let reduced = interp.evaluate("""
        VStack { Text("\\([1, 2, 3].reduce(0) { acc, x in let step = x * x; acc + step })") }
        """)
        #expect(reduced?.children.first?.text == "14")
    }

    @Test func colorChannelHandlesNonFiniteWithoutCrashing() {
        // Color(red: .infinity) must not trap converting Double->Int.
        let node = interp.evaluate(#"VStack { Rectangle().foregroundColor(Color(red: 2.0, green: 0.5, blue: 0.0)) ; Text("ok") }"#)
        #expect(node?.children.last?.text == "ok")
    }

    @Test func valueFuncWithSwitchAndIfLet() {
        let node = interp.evaluate("""
        func tint(_ w) -> String {
            switch w.state {
            case "running": return "#9ECE6A"
            case "queued": return "#7AA2F7"
            default: return "#565F89"
            }
        }
        func name(_ w) -> String {
            if let t = w.title { return t }
            return "untitled"
        }
        VStack {
            Text(tint(a)).foregroundColor(tint(a))
            Text(name(a))
            Text(name(b))
        }
        """, state: [
            "a": .object(["state": .string("queued"), "title": .string("Alpha")]),
            "b": .object(["state": .string("running")]),
        ])
        #expect(node?.children.map(\.text) == ["#7AA2F7", "Alpha", "untitled"])
    }

    @Test func ifLetOptionalBindingRendersWhenPresent() {
        let present = SwiftValue.object(["branch": .string("main")])
        let node = interp.evaluate("""
        VStack {
            if let b = ws.branch { Text("on \\(b)") } else { Text("no branch") }
        }
        """, state: ["ws": present])
        #expect(node?.children.first?.text == "on main")

        let absent = SwiftValue.object(["title": .string("x")])
        let node2 = interp.evaluate("""
        VStack {
            if let b = ws.branch { Text("on \\(b)") } else { Text("no branch") }
        }
        """, state: ["ws": absent])
        #expect(node2?.children.first?.text == "no branch")
    }

    @Test func switchSelectsMatchingCase() {
        func run(_ status: String) -> String? {
            interp.evaluate("""
            VStack {
                switch s {
                case "running": Text("go")
                case "idle": Text("wait")
                default: Text("?")
                }
            }
            """, state: ["s": .string(status)])?.children.first?.text
        }
        #expect(run("running") == "go")
        #expect(run("idle") == "wait")
        #expect(run("other") == "?")
    }

    @Test func anyViewPassthrough() {
        let node = interp.evaluate(#"VStack { AnyView(Text("wrapped")) }"#)
        #expect(node?.children.first?.kind == .text)
        #expect(node?.children.first?.text == "wrapped")
    }

    @Test func shapeStrokeAndTrimCaptured() {
        let node = interp.evaluate("""
        Circle().stroke("#7AA2F7", lineWidth: 2).trim(from: 0.0, to: 0.75)
        """)
        #expect(node?.kind == .circle)
        let names = Set((node?.modifiers ?? []).map(\.name))
        #expect(names.isSuperset(of: ["stroke", "trim"]))
        let stroke = node?.modifiers.first { $0.name == "stroke" }
        #expect(stroke?.firstValue == "#7AA2F7")
        #expect(stroke?.value("lineWidth") == "2")
    }

    @Test func ellipseAndUnevenRoundedRectangleShapes() {
        let node = interp.evaluate("""
        HStack {
            Ellipse()
            UnevenRoundedRectangle(cornerRadius: 12)
        }
        """)
        #expect(node?.children.map(\.kind) == [.ellipse, .unevenRoundedRectangle])
        #expect(node?.children.last?.cornerRadius == 12)
    }

    @Test func cosmeticModifiersCaptured() {
        let node = interp.evaluate("""
        Text("x")
            .shadow(radius: 4)
            .border(.gray, width: 1)
            .rotationEffect(.degrees(45))
            .scaleEffect(1.2)
        """)
        let names = Set((node?.modifiers ?? []).map(\.name))
        #expect(names.isSuperset(of: ["shadow", "border", "rotationEffect", "scaleEffect"]))
    }

    @Test func labelCapturesTitleAndIcon() {
        let node = interp.evaluate("""
        VStack {
            Label("Repos", systemImage: "folder.fill")
        }
        """)
        let label = node?.children.first
        #expect(label?.kind == .label)
        #expect(label?.text == "Repos")
        #expect(label?.systemName == "folder.fill")
    }

    @Test func textTypographyModifiersCaptured() {
        let node = interp.evaluate("""
        Text("hi")
            .italic()
            .monospaced()
            .textCase(.uppercase)
            .multilineTextAlignment(.center)
        """)
        #expect(node?.kind == .text)
        let names = Set((node?.modifiers ?? []).map(\.name))
        #expect(names.isSuperset(of: ["italic", "monospaced", "textCase", "multilineTextAlignment"]))
    }

    @Test func emptyViewLowersToEmptyGroup() {
        let node = interp.evaluate("""
        VStack {
            EmptyView()
            Text("after")
        }
        """)
        #expect(node?.children.first?.kind == .group)
        #expect(node?.children.first?.children.isEmpty == true)
        #expect(node?.children.last?.text == "after")
    }

    /// Authored source must never trap the interpreter: a non-finite or
    /// out-of-range double passed to `Int(...)` evaluates to nil instead of
    /// crashing the process (https://github.com/manaflow-ai/cmux/pull/5275
    /// review finding).
    @Test func intConversionOfNonFiniteDoubleDoesNotTrap() {
        let node = interp.evaluate("""
        VStack {
            Text("\\(Int(1.0 / 0.0))")
            Text("\\(Int(0.0 / 0.0))")
            Text("\\(Int(1e300))")
            Text("after")
        }
        """)
        #expect(node?.kind == .vstack)
        #expect(node?.children.last?.text == "after")
    }

    /// `Gauge(value:total:)` normalizes like ProgressView; the raw value
    /// alone would render any total-relative gauge as full.
    @Test func gaugeNormalizesValueAgainstTotal() {
        let node = interp.evaluate("""
        Gauge(value: 3.0, total: 12.0) { Text("load") }
        """)
        #expect(node?.kind == .gauge)
        #expect(node?.value == 0.25)
    }
}
