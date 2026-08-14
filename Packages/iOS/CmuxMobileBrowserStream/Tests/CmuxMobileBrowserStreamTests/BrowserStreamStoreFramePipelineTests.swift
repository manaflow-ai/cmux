import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// Regression coverage for the store-owned frame pipeline.
///
/// The store, not a view coordinator, must consume the decoder stream: an
/// AsyncStream dies permanently when its consuming task is cancelled, and a
/// view-owned consumer stalled the whole stream on the first SwiftUI remount
/// (frames froze while state events kept flowing, and the Mac's unacked
/// window filled). These tests pin the store-lifetime behavior.
@MainActor
struct BrowserStreamStoreFramePipelineTests {
    /// A 1x1 opaque PNG.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg=="

    private func frameEventData(panelID: String, sequence: UInt64) throws -> Data {
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

    private func discoveredStore(panelID: String, workspaceID: String) -> BrowserStreamStore {
        let store = BrowserStreamStore()
        store.replacePanels(
            in: workspaceID,
            with: [
                MobileBrowserPanelDescriptor(
                    panelID: panelID,
                    workspaceID: workspaceID,
                    url: "https://example.com",
                    title: "Example",
                    pageWidth: 100,
                    pageHeight: 100,
                    canGoBack: false,
                    canGoForward: false,
                    isLoading: false
                )
            ]
        )
        return store
    }

    private func waitForLatestFrame(
        _ store: BrowserStreamStore,
        panelID: String,
        timeout: TimeInterval = 5
    ) async -> BrowserStreamFrame? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if let frame = store.state(for: panelID)?.latestFrame { return frame }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store.state(for: panelID)?.latestFrame
    }

    @Test func framePayloadInstallsLatestFrameAndAcknowledges() async throws {
        let panelID = "11111111-1111-1111-1111-111111111111"
        let store = discoveredStore(panelID: panelID, workspaceID: "ws-1")
        var acked: [(String, UInt64)] = []
        let ackBox = AckBox()

        store.receiveBrowserFramePayload(
            try frameEventData(panelID: panelID, sequence: 1)
        ) { panel, sequence in
            await ackBox.record(panel: panel, sequence: sequence)
        }

        let frame = await waitForLatestFrame(store, panelID: panelID)
        #expect(frame != nil)
        #expect(frame?.sequence == 1)
        acked = await ackBox.entries
        #expect(acked.count == 1)
        #expect(acked.first?.0 == panelID)
        #expect(acked.first?.1 == 1)
    }

    @Test func framePipelineSurvivesWithoutAnyViewConsumer() async throws {
        // No representable, no coordinator, no frames(for:) accessor: payload
        // in, observable latestFrame out. This is the whole remount-safety
        // contract.
        let panelID = "22222222-2222-2222-2222-222222222222"
        let store = discoveredStore(panelID: panelID, workspaceID: "ws-2")
        let ackBox = AckBox()

        for sequence in UInt64(1)...3 {
            store.receiveBrowserFramePayload(
                try frameEventData(panelID: panelID, sequence: sequence)
            ) { panel, seq in
                await ackBox.record(panel: panel, sequence: seq)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if store.state(for: panelID)?.latestFrame?.sequence == 3 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.state(for: panelID)?.latestFrame?.sequence == 3)
        let acked = await ackBox.entries
        #expect(acked.map(\.1).max() == 3)
    }
}

private actor AckBox {
    var entries: [(String, UInt64)] = []

    func record(panel: String, sequence: UInt64) {
        entries.append((panel, sequence))
    }
}
