#if os(iOS)
@testable import CmuxMobileDesign
import Testing
import UIKit

/// A UIKit list under the connection banner: it carries the banner's slot as
/// extra top inset, only the difference each time (other owners of the inset,
/// such as pull to refresh, keep theirs), and a list at its top stays there.
@MainActor @Suite struct BannerContentInsetTests {
    private func list() -> UIScrollView {
        let view = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        view.contentSize = CGSize(width: 390, height: 4000)
        view.contentInsetAdjustmentBehavior = .never
        return view
    }

    @Test func aBannerInsetsTheListAndKeepsItAtItsTop() {
        let view = list()
        var banner = BannerContentInset()
        banner.apply(52, to: view)
        #expect(view.contentInset.top == 52)
        #expect(view.verticalScrollIndicatorInsets.top == 52)
        #expect(view.contentOffset.y == -52, "the first line starts under the banner")
        banner.apply(0, to: view)
        #expect(view.contentInset.top == 0)
        #expect(view.contentOffset.y == 0, "no banner: the list is back under the bar")
    }

    @Test func otherInsetOwnersKeepTheirs() {
        let view = list()
        view.contentInset.top = 40 // a refresh holding its slot open
        var banner = BannerContentInset()
        banner.apply(52, to: view)
        #expect(view.contentInset.top == 92)
        banner.apply(70, to: view) // the banner wrapped to two lines
        #expect(view.contentInset.top == 110)
        banner.apply(0, to: view)
        #expect(view.contentInset.top == 40)
    }

    @Test func aScrolledListDoesNotMove() {
        let view = list()
        view.contentOffset.y = 600
        var banner = BannerContentInset()
        banner.apply(52, to: view)
        #expect(view.contentOffset.y == 600, "rows read mid-list stay where they are")
    }
}
#endif
