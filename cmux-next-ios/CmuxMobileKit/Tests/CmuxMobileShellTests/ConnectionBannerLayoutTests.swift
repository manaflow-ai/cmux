#if os(iOS)
@testable import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// The connection banner at every text size: a short state is one 36 pt line,
/// and a long one (signed out, "This device was signed out. Sign in again")
/// wraps inside the phone's width instead of clipping, its Sign in button
/// still in the banner.
@MainActor @Suite struct ConnectionBannerLayoutTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility2, .accessibility5]
    /// An iPhone's width in points (the narrowest current one is 375).
    static let width: CGFloat = 375

    private func size(_ state: ConnectionBannerState, _ type: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: ConnectionBanner(state, retry: {}).dynamicTypeSize(type))
        return host.sizeThatFits(in: CGSize(width: Self.width, height: 2000))
    }

    @Test(arguments: sizes) func theSignedOutBannerWrapsWithinThePhone(type: DynamicTypeSize) {
        let banner = size(.signedOut, type)
        #expect(banner.width <= Self.width, "\(type): \(banner.width) pt wide")
        #expect(banner.height >= 36, "\(type): \(banner.height) pt tall")
    }

    /// Larger text makes the banner taller (more lines), never clipped to one.
    @Test func largerTextWrapsToMoreLines() {
        let large = size(.signedOut, .large).height
        let accessibility = size(.signedOut, .accessibility2).height
        let oneLine = size(.offline, .accessibility2).height
        #expect(accessibility > large, "large \(large) pt, accessibility2 \(accessibility) pt")
        #expect(accessibility > oneLine, "signed out \(accessibility) pt, one-line Offline \(oneLine) pt")
    }

    /// A short state keeps the one-line capsule.
    @Test func aShortStateIsOneLine() {
        #expect(size(.offline, .large).height == 36)
    }

    /// Past accessibility2 the banner stops growing: it sits over the list.
    @Test func textSizeIsCappedAtAccessibility2() {
        #expect(size(.signedOut, .accessibility5) == size(.signedOut, .accessibility2))
    }
}
#endif
