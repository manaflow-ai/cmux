#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// The shared Retry is a capsule: wider than tall at every text size, so a
/// short title never draws as a circle (a 44 pt label height inside a glass
/// button made "Retry" about 60 x 58 pt, a circle in loading pages).
@MainActor @Suite struct RetryButtonShapeTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.small, .large, .xxxLarge, .accessibility3]

    private func size(_ view: some View, _ type: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.dynamicTypeSize(type))
        return host.sizeThatFits(in: CGSize(width: 400, height: 400))
    }

    @Test(arguments: sizes) func retryIsACapsuleNotACircle(type: DynamicTypeSize) {
        let fitted = size(RetryButton {}, type)
        #expect(fitted.height > 0)
        // A capsule: clearly wider than tall (a circle is 1:1).
        #expect(fitted.width >= fitted.height * 1.5, "Retry is \(fitted.width) x \(fitted.height) pt")
    }

    @Test func retryKeepsTheInlineCapsuleHeight() {
        // SPEC 4.1 inline capsule: 40 pt drawn in a 44 pt target, never taller.
        let fitted = size(RetryButton {}, .large)
        #expect(fitted.height <= 44, "Retry is \(fitted.height) pt tall")
    }

    @Test func retryGrowsWithAccessibilityTextInsteadOfClipping() {
        // Its title at AX3 is taller than 40 pt; the capsule holds it.
        let large = size(RetryButton {}, .large)
        let ax = size(RetryButton {}, .accessibility3)
        #expect(ax.height > large.height, "Retry is \(ax.height) pt tall at AX3")
    }
}
#endif
