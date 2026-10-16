import Testing
import SwiftUI
import UIKit

@testable import CmuxMobileShellUI

@Suite("Horizontal edge fade")
struct HorizontalEdgeFadeTests {
    @Test("Files chips reach the sheet edge without a leading fade")
    @MainActor
    func filesLeadingEdge() throws {
        let controller = HorizontalEdgeFadePillBarViewController(
            contentInsets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 12),
            fadesLeadingEdge: false,
            accessibilityIdentifier: "FilesTest",
            leading: EmptyView(),
            pills: Color.blue.frame(width: 600, height: 34),
            trailing: Text("Recent")
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 340, height: 34)
        controller.view.layoutIfNeeded()
        let scrollView = try #require(controller.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(scrollView.frame.minX == 0)
        #expect(scrollView.contentOffset.x == -16)
        #expect(scrollView.clipsToBounds)
        scrollView.contentOffset.x = 80
        scrollView.layoutIfNeeded()
        let mask = try #require(scrollView.layer.mask as? CAGradientLayer)
        let colors = try #require(mask.colors as? [CGColor])
        #expect(colors.first?.alpha == 1)
        #expect(colors.last?.alpha == 0)
        #expect(mask.frame == scrollView.bounds)
    }

    @Test("edge stays opaque at rest")
    func opaqueAtRest() {
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 0) == 1)
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: -4) == 1)
    }

    @Test("fade ramps linearly as content approaches a control edge")
    func incrementalRamp() {
        #expect(abs(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 6) - 0.75) < 0.0001)
        #expect(abs(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 12) - 0.5) < 0.0001)
    }

    @Test("fade saturates after one band")
    func saturates() {
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 24) == 0)
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 500) == 0)
    }
}
