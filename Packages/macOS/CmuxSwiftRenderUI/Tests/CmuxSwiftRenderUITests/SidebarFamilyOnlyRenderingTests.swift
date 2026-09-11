import AppKit
import CmuxSwiftRender
import SwiftUI
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Family-only sidebar fonts")
@MainActor
struct SidebarFamilyOnlyRenderingTests {
    @Test("JSON family-only fonts use the default body size")
    func jsonFamilyOnlyFontRenders() throws {
        let familyOnly = try jsonPixels(#"{"type":"text","text":"Sidebar 123","family":"Menlo"}"#)
        let explicitSize = try jsonPixels(#"{"type":"text","text":"Sidebar 123","family":"Menlo","size":13}"#)
        let system = try jsonPixels(#"{"type":"text","text":"Sidebar 123","size":13}"#)

        #expect(familyOnly == explicitSize)
        #expect(familyOnly != system)
    }

    @Test("JavaScript family-only fonts use the default body size")
    func javaScriptFamilyOnlyFontRenders() throws {
        let familyOnly = try javaScriptPixels(#"{ family: "Menlo" }"#)
        let explicitSize = try javaScriptPixels(#"{ family: "Menlo", size: 13 }"#)
        let system = try javaScriptPixels("13")

        #expect(familyOnly == explicitSize)
        #expect(familyOnly != system)
    }

    private func jsonPixels(_ source: String) throws -> Data {
        let node = try JSONDecoder().decode(DSLNode.self, from: Data(source.utf8))
        return try pixels(DSLSidebarRenderer(node: node, onAction: { _ in }))
    }

    private func javaScriptPixels(_ font: String) throws -> Data {
        let runtime = SidebarJSRuntime()
        #expect(runtime.start(source: "sidebar(() => Text(\"Sidebar 123\").font(\(font)))"))
        let rootId = try #require(runtime.store.rootId)
        return try pixels(SceneNodeView(nodeId: rootId).environment(\.sceneStore, runtime.store))
    }

    private func pixels(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content:
            view
                .foregroundStyle(.black)
                .frame(width: 240, height: 56, alignment: .leading)
                .background(.white)
        )
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data) as Data
    }
}
