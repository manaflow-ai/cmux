import Foundation
import CmuxSwiftRender
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar font family")
struct SidebarFontFamilyTests {
    @Test("JSON nodes retain an explicit family")
    func jsonNodeRetainsFamily() throws {
        let data = Data(
            #"{"type":"text","text":"row","family":"MonoLisaText","size":13}"#.utf8
        )
        let node = try JSONDecoder().decode(DSLNode.self, from: data)

        #expect(node.family == "MonoLisaText")
        #expect(node.size == 13)
    }

    @Test("Swift custom font tokens retain the family")
    func swiftCustomFontTokenRetainsFamily() {
        let spec = dslFontSpec(
            named: nil,
            size: 13,
            family: " MonoLisaText ")

        #expect(spec?.family == "MonoLisaText")
        #expect(spec?.baseSize == 13)
    }

    @Test("Swift custom font syntax reaches the render modifier")
    func swiftCustomFontSyntaxReachesRenderModifier() throws {
        let node = try #require(SwiftViewInterpreter().evaluate(
            #"Text("row").font(.custom("MonoLisaText", size: 13))"#
        ))

        let modifier = try #require(node.modifiers.first)
        #expect(modifier.name == "font")
        let spec = dslFontSpec(from: modifier.firstValue)
        #expect(spec?.family == "MonoLisaText")
        #expect(spec?.baseSize == 13)
    }

    @Test("Swift system font tokens retain their design")
    func swiftSystemFontTokenRetainsDesign() throws {
        let rounded = dslFontSpec(from: ".system(size: 13, design: .rounded)")
        let serif = dslFontSpec(from: ".system(size: 13, design: .serif)")

        #expect(rounded?.design == .rounded)
        #expect(serif?.design == .serif)
    }
}
