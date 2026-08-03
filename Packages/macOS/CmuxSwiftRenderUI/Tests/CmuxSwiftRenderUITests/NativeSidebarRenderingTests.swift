import AppKit
import CmuxSwiftRender
import Foundation
import Testing

@testable import CmuxSwiftRenderUI

@Suite("Native custom sidebar rendering")
@MainActor
struct NativeSidebarRenderingTests {
  @Test("declarative buttons publish native hit regions and actions")
  func declarativeButtonPublishesHitRegion() throws {
    let document = try JSONDecoder().decode(
      DSLDocument.self,
      from: Data(
        """
        {
          "version": 1,
          "root": {
            "type": "vstack",
            "children": [
              {
                "type": "button",
                "title": "Run",
                "action": { "type": "log", "message": "native" }
              }
            ]
          }
        }
        """.utf8)
    )
    let view = CustomSidebarContentView(
      state: .json(document),
      swiftRender: nil,
      hasRenderedSwift: false,
      dispatch: .noop,
      contentInsets: .zero
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()

    let targets = view.tapTargets()

    #expect(targets.count == 1)
    #expect(targets.first?.frame.width ?? 0 > 0)
    #expect(targets.first?.frame.height ?? 0 > 0)
    #expect(targets.first?.action == ButtonAction(commands: [.log("native")]))
  }
}
