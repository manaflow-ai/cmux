#if os(iOS)
@testable import CmuxTabsKit
import Observation
import SwiftUI
import Testing
import UIKit

/// CMUX-15: the page menu's rows are built when the menu opens, never while the page is on
/// screen with the menu closed. Built in `TabsView.body`, every value the rows read (an agent
/// chat's turns as they stream) re-ran the whole tab view and rebuilt the hidden menu.
@MainActor @Suite(.serialized) struct PageMenuLazyTests {
    @Observable @MainActor final class Source: TabsDataSource {
        var tabs = [TabsKitTab(id: "t", kind: .web, title: "T", address: .title("T"), features: [.pageMenu])]
        var activeTabID: TabsKitTab.ID? = "t"
        var newTabOptions = [TabsKitNewTabOption(id: "web", title: "New Tab", systemImage: "plus", kind: .web)]
        /// What a row reads, as a chat's turns: it changes while the page is on screen.
        var streamed = 0
        /// Times the kit asked for the page menu.
        @ObservationIgnored var pageMenuCalls = 0
        /// Times the page's content was asked for (the view rendered at all).
        @ObservationIgnored var contentCalls = 0

        func activate(_ id: TabsKitTab.ID) { activeTabID = id }
        func close(_ id: TabsKitTab.ID) async -> Bool { false }
        func createTab(_ option: TabsKitNewTabOption) async -> TabsKitTab.ID? { nil }
        func content(for tab: TabsKitTab, context: TabsKitContentContext) -> some View {
            contentCalls += 1
            return Color.clear
        }

        func pageMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]] {
            pageMenuCalls += 1
            return [[TabsKitMenuItem(title: "Turns: \(streamed)", systemImage: "text.bubble") {}]]
        }
    }

    func settle(_ window: UIWindow) async {
        for _ in 0 ..< 5 {
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    @Test func aClosedMenuIsNeverBuiltNorFollowsWhatItsRowsRead() async {
        let source = Source()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: TabsView(source: source))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        #expect(source.contentCalls > 0, "the tab view never rendered its page")
        for _ in 0 ..< 20 {
            source.streamed += 1
            await settle(window)
        }
        #expect(source.pageMenuCalls == 0, "built the closed page menu \(source.pageMenuCalls) times")
    }
}
#endif
