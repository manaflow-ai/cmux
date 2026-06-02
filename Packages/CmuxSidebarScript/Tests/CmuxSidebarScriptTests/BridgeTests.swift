import Testing
@testable import CmuxSidebarScript

@Suite struct BridgeTests {
    @Test func textNodeCarriesContentAndFontModifier() throws {
        let node = try #require(try run("""
        (text "hello"
          :font (font :size 13 :weight semibold)
          :foreground (color :red))
        """).asNode)
        #expect(node.kind == "text")
        #expect(node.content["text"]?.string == "hello")
        let font = try #require(node.modifier("font"))
        #expect(font.first == .font(RNFont(size: 13, weight: "semibold")))
        let fg = try #require(node.modifier("foreground"))
        #expect(fg.first == .color(.named("red")))
    }

    @Test func stackParamsAndChildren() throws {
        let node = try #require(try run("""
        (vstack :spacing 4 :alignment leading
          (text "a")
          (text "b"))
        """).asNode)
        #expect(node.kind == "vstack")
        #expect(node.content["spacing"] == .number(4))
        #expect(node.content["alignment"] == .alignment(RNAlignment("leading")))
        #expect(node.children.count == 2)
        #expect(node.containsText("a"))
        #expect(node.containsText("b"))
    }

    @Test func mapResultSplicesAsChildren() throws {
        let node = try #require(try run("""
        (hstack (map (fn (n) (text (str n))) (list 1 2 3)))
        """).asNode)
        #expect(node.children.count == 3)
        #expect(node.containsText("1"))
        #expect(node.containsText("3"))
    }

    @Test func nilChildIsDropped() throws {
        let node = try #require(try run("""
        (vstack (text "a") (when false (text "b")) (text "c"))
        """).asNode)
        #expect(node.children.count == 2)
    }

    @Test func hexColorAndPadding() throws {
        let node = try #require(try run("""
        (text "x" :background (hex "#ff8800") :padding (edges :horizontal 6 :vertical 2))
        """).asNode)
        #expect(node.modifier("background")?.first == .color(.hex("#ff8800")))
        let padding = try #require(node.modifier("padding"))
        #expect(padding.first == .edges(RNEdges(top: 2, leading: 6, bottom: 2, trailing: 6)))
    }

    @Test func frameOptionsCoalesce() throws {
        let node = try #require(try run("""
        (text "x" :max-width infinity :frame-align leading)
        """).asNode)
        let frame = try #require(node.modifier("frame"))
        #expect(frame.named["max-width"] == .number(.infinity))
        #expect(frame.named["frame-align"] == .alignment(RNAlignment("leading")))
    }

    @Test func modifierOrderIsPreserved() throws {
        let node = try #require(try run("""
        (text "x" :padding 4 :background (color :red) :corner-radius 6)
        """).asNode)
        #expect(node.modifiers.map(\.name) == ["padding", "background", "corner-radius"])
    }

    @Test func unknownModifierThrows() {
        #expect(throws: LispError.self) { try run("(text \"x\" :bogus 1)") }
    }

    @Test func onTapCarriesAction() throws {
        let node = try #require(try run("""
        (text "open" :on-tap (open-url "https://example.com"))
        """).asNode)
        let tap = try #require(node.modifier("on-tap"))
        #expect(tap.first == .action(RNAction(kind: "open-url", payload: ["url": "https://example.com"])))
    }

    @Test func gradientBackground() throws {
        let node = try #require(try run("""
        (rectangle :fill (gradient (color :red) (color :blue) :direction horizontal))
        """).asNode)
        #expect(node.content["fill"] == .gradient(RNGradient(colors: [.named("red"), .named("blue")], direction: .horizontal)))
    }

    @Test func gridCarriesColumnsAndChildren() throws {
        let node = try #require(try run("""
        (grid :columns 3 :spacing 2
          (text "a")
          (text "b")
          (text "c"))
        """).asNode)
        #expect(node.kind == "grid")
        #expect(node.content["columns"] == .number(3))
        #expect(node.content["spacing"] == .number(2))
        #expect(node.children.count == 3)
    }

    @Test func maskAndScaleModifiersCarryNodesAndNumbers() throws {
        let node = try #require(try run("""
        (text "x" :scale 1.2 :minimum-scale-factor 0.7 :mask (circle :fill (color :white)))
        """).asNode)
        #expect(node.modifier("scale")?.first == .number(1.2))
        #expect(node.modifier("minimum-scale-factor")?.first == .number(0.7))
        #expect(node.modifier("mask")?.first == .node(RenderNode(
            kind: "circle",
            content: ["fill": .color(.named("white"))]
        )))
    }
}
