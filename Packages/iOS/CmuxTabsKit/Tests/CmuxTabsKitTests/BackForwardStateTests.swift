@testable import CmuxTabsKit
import Testing

private func tab(back: Bool, forward: Bool, features: TabsKitTabFeatures = .web) -> TabsKitTab {
    TabsKitTab(id: "t", kind: .web, title: "A", address: .url(display: "cmux.dev", editingText: "https://cmux.dev/a"),
               navigation: TabsKitNavigationState(canGoBack: back, canGoForward: forward), features: features)
}

struct BackForwardStateTests {
    /// The capsule's state follows the tab's history flags.
    @Test func capsuleFollowsHistory() {
        let none = BackForwardState(tab: tab(back: false, forward: false), sidesVisible: true, editing: false)
        #expect(none.visible && !none.backEnabled && !none.forwardShown)
        let back = BackForwardState(tab: tab(back: true, forward: false), sidesVisible: true, editing: false)
        #expect(back.backEnabled && !back.forwardShown)
        let both = BackForwardState(tab: tab(back: true, forward: true), sidesVisible: true, editing: false)
        #expect(both.backEnabled && both.forwardShown)
        let fwdOnly = BackForwardState(tab: tab(back: false, forward: true), sidesVisible: true, editing: false)
        #expect(!fwdOnly.backEnabled && fwdOnly.forwardShown)
    }

    /// Tabs without history, the collapsed pill and address editing hide the controls.
    @Test func hiddenWhereThereIsNoHistory() {
        let noHistory = tab(back: true, forward: true, features: [.pageMenu])
        #expect(!BackForwardState(tab: noHistory, sidesVisible: true, editing: false).visible)
        #expect(!BackForwardState(tab: noHistory, sidesVisible: true, editing: false).forwardShown)
        #expect(!BackForwardState(tab: tab(back: true, forward: false), sidesVisible: false, editing: false).backEnabled)
        #expect(!BackForwardState(tab: tab(back: true, forward: false), sidesVisible: true, editing: true).backEnabled)
        #expect(!BackForwardState(tab: nil, sidesVisible: true, editing: false).backEnabled)
    }

    @Test func addressLabels() {
        #expect(TabsKitAddress.url(display: "cmux.dev", editingText: "https://cmux.dev/").label == "cmux.dev")
        #expect(TabsKitAddress.placeholder("Search").label == "Search")
        #expect(TabsKitAddress.title("zsh", subtitle: "~/src", monospaced: true).label == "zsh")
        #expect(TabsKitTabFeatures.web.contains([.history, .reload, .addressEditing, .pageMenu]))
    }
}
