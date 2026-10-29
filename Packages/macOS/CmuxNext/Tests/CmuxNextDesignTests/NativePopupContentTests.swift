import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor struct NativePopupContentTests {
    @Test func searchDescriptorUpdatesWithoutChangingItsIdentity() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.search = NativePopupField(id: "query", value: "a", placeholder: "Search")
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        model.revision += 1
        model.search = NativePopupField(id: "query", value: "b", placeholder: "Unavailable", disabled: true)
        content.update(model)
        #expect(field.stringValue == "b")
        #expect(field.placeholderString == "Unavailable")
        #expect(!field.isEnabled)
    }

    @Test func documentTracksAClampedViewport() {
        let viewport = NSClipView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        viewport.documentView = content
        content.update(Self.model())
        content.layout()
        #expect(content.frame.width == viewport.bounds.width)
        #expect(content.subviews.allSatisfy { $0.frame.maxX <= viewport.bounds.width })
    }

    private static func model() -> NativePopupModel {
        NativePopupModel(schemaVersion: 1, id: "content", revision: 1,
                         anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                         side: .bottom, align: .start, width: 320,
                         rows: [NativePopupRow(id: "pick", kind: .action, label: "Pick")])
    }
}
