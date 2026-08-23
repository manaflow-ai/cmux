import AppKit
import CmuxSwiftRender
import SwiftUI
import Testing

@testable import CmuxSwiftRenderUI

@MainActor
@Suite("Custom sidebar scroller")
struct CustomSidebarScrollerTests {
  @Test("Custom sidebars suppress scroll indicators")
  func customSidebarsSuppressScrollIndicators() async throws {
    let content = CustomSidebarContentView(
      state: .failed(String(repeating: "Overflowing sidebar content\n", count: 100)),
      swiftRender: nil,
      hasRenderedSwift: true,
      dispatch: .noop,
      contentInsets: .zero
    )
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: 240, height: 400)

    host.layoutSubtreeIfNeeded()
    await Task.yield()
    host.layoutSubtreeIfNeeded()

    let scrollView = try #require(firstScrollView(in: host))
    #expect(!scrollView.hasVerticalScroller)
    #expect(!scrollView.hasHorizontalScroller)
  }

  @Test("Split custom sidebars suppress indicators in every column")
  func splitCustomSidebarsSuppressScrollIndicators() async throws {
    let node = RenderNode(
      kind: .hsplit,
      children: [
        RenderNode(kind: .text, text: "Left"),
        RenderNode(kind: .text, text: "Right"),
      ]
    )
    let content = CustomSidebarContentView(
      state: .swiftSource("HSplitView {}"),
      swiftRender: node,
      hasRenderedSwift: true,
      dispatch: .noop,
      contentInsets: .zero
    )
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)

    host.layoutSubtreeIfNeeded()
    await Task.yield()
    host.layoutSubtreeIfNeeded()

    let scrollViews = descendants(of: NSScrollView.self, in: host)
    #expect(scrollViews.count == 2)
    #expect(scrollViews.allSatisfy { !$0.hasVerticalScroller && !$0.hasHorizontalScroller })
  }

  private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    return view.subviews.lazy.compactMap(firstScrollView).first
  }

  private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
    var matches = (root as? View).map { [$0] } ?? []
    for subview in root.subviews {
      matches.append(contentsOf: descendants(of: type, in: subview))
    }
    return matches
  }
}
