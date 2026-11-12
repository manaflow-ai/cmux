import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

@MainActor
struct BrowserStreamStorePanelRetirementTests {
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg=="

    private func descriptor(panelID: String, workspaceID: String) -> MobileBrowserPanelDescriptor {
        MobileBrowserPanelDescriptor(
            panelID: panelID,
            workspaceID: workspaceID,
            url: nil,
            title: nil,
            pageWidth: 100,
            pageHeight: 100,
            canGoBack: false,
            canGoForward: false,
            isLoading: false
        )
    }

    private func closedPayload(panelID: String) throws -> Data {
        try JSONEncoder().encode(MobileBrowserClosedEvent(panelID: panelID))
    }

    private func framePayload(panelID: String, sequence: UInt64) throws -> Data {
        try JSONEncoder().encode(
            MobileBrowserFrameEvent(
                panelID: panelID,
                sequence: sequence,
                format: .png,
                pageWidth: 100,
                pageHeight: 100,
                pixelWidth: 1,
                pixelHeight: 1,
                dataBase64: Self.pngBase64
            )
        )
    }

    @Test func closedPanelReleasesItsState() throws {
        let store = BrowserStreamStore()
        store.replacePanels(in: "ws-1", with: [descriptor(panelID: "panel-a", workspaceID: "ws-1")])
        let state = try #require(store.activate(panelID: "panel-a", in: "ws-1"))

        let closedID = store.receiveBrowserClosedPayload(try closedPayload(panelID: "panel-a"))

        #expect(closedID == "panel-a")
        #expect(state.streamStatus == .closed)
        #expect(store.state(for: "panel-a") == nil)
        #expect(store.activeState(in: "ws-1") == nil)
        #expect(store.panels(in: "ws-1").isEmpty)
    }

    @Test func frameForClosedPanelDoesNotResurrectState() async throws {
        let store = BrowserStreamStore()
        store.replacePanels(in: "ws-1", with: [descriptor(panelID: "panel-a", workspaceID: "ws-1")])
        _ = store.receiveBrowserClosedPayload(try closedPayload(panelID: "panel-a"))

        let panelID = store.receiveBrowserFramePayload(try framePayload(panelID: "panel-a", sequence: 1)) { _, _ in }
        await store.browserStreamWillStart(panelID: "panel-a")

        #expect(panelID == "panel-a")
        #expect(store.state(for: "panel-a") == nil)
    }

    @Test func panelDroppedFromDiscoveryIsRetired() {
        let store = BrowserStreamStore()
        store.replacePanels(
            in: "ws-1",
            with: [
                descriptor(panelID: "panel-a", workspaceID: "ws-1"),
                descriptor(panelID: "panel-b", workspaceID: "ws-1"),
            ]
        )

        store.replacePanels(in: "ws-1", with: [descriptor(panelID: "panel-b", workspaceID: "ws-1")])

        #expect(store.state(for: "panel-a") == nil)
        #expect(store.state(for: "panel-b") != nil)
    }

    @Test func panelMovedToAnotherWorkspaceKeepsItsState() {
        let store = BrowserStreamStore()
        store.replacePanels(in: "ws-1", with: [descriptor(panelID: "panel-a", workspaceID: "ws-1")])
        let original = store.state(for: "panel-a")
        store.replacePanels(in: "ws-2", with: [descriptor(panelID: "panel-a", workspaceID: "ws-2")])

        store.replacePanels(in: "ws-1", with: [])

        #expect(store.state(for: "panel-a") === original)
    }
}
