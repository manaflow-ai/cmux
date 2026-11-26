import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// Coverage for phone-initiated panel creation: the New Browser button relies
/// on the created descriptor being activatable before any discovery refresh.
@MainActor
struct BrowserStreamStorePanelCreationTests {
    private func descriptor(
        panelID: String,
        workspaceID: String,
        title: String? = nil
    ) -> MobileBrowserPanelDescriptor {
        MobileBrowserPanelDescriptor(
            panelID: panelID,
            workspaceID: workspaceID,
            url: nil,
            title: title,
            pageWidth: 800,
            pageHeight: 600,
            canGoBack: false,
            canGoForward: false,
            isLoading: false
        )
    }

    @Test func createdPanelIsImmediatelyActivatable() {
        let store = BrowserStreamStore()
        store.browserPanelCreated(descriptor(panelID: "panel-new", workspaceID: "ws-1"))

        #expect(store.panels(in: "ws-1").map(\.panelID) == ["panel-new"])
        let state = store.activate(panelID: "panel-new", in: "ws-1")
        #expect(state != nil)
        #expect(store.activeState(in: "ws-1")?.id == "panel-new")
    }

    @Test func repeatedCreationUpdatesInsteadOfDuplicating() {
        let store = BrowserStreamStore()
        store.browserPanelCreated(descriptor(panelID: "panel-new", workspaceID: "ws-1"))
        store.browserPanelCreated(descriptor(panelID: "panel-new", workspaceID: "ws-1", title: "Example"))

        let panels = store.panels(in: "ws-1")
        #expect(panels.count == 1)
        #expect(panels.first?.title == "Example")
    }

    @Test func createdPanelJoinsExistingDiscovery() {
        let store = BrowserStreamStore()
        store.replacePanels(in: "ws-1", with: [descriptor(panelID: "panel-old", workspaceID: "ws-1")])
        store.browserPanelCreated(descriptor(panelID: "panel-new", workspaceID: "ws-1"))

        #expect(store.panels(in: "ws-1").map(\.panelID) == ["panel-old", "panel-new"])
    }
}
