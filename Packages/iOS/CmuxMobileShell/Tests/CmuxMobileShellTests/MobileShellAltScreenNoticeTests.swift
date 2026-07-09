import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellAltScreenNoticeTests {
    @Test func alternateScreenAccessorTracksRenderGridFrames() throws {
        let suiteName = "altscreen-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = Self.makeStore(defaults: defaults)

        #expect(store.isAlternateScreen(surfaceID: "surface-a") == false)

        store.recordTerminalRenderGridDelivery(try Self.renderGridFrame(
            surfaceID: "surface-a",
            seq: 1,
            activeScreen: .alternate
        ))
        #expect(store.isAlternateScreen(surfaceID: "surface-a"))
        #expect(store.isAlternateScreen(surfaceID: "unknown-surface") == false)

        store.recordTerminalRenderGridDelivery(try Self.renderGridFrame(
            surfaceID: "surface-a",
            seq: 2,
            activeScreen: .primary
        ))
        #expect(store.isAlternateScreen(surfaceID: "surface-a") == false)
    }

    @Test func sameActiveScreenRenderGridDoesNotNotifyAlternateScreenObservers() async throws {
        let suiteName = "altscreen-observation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = Self.makeStore(defaults: defaults)
        let surfaceID = "surface-a"

        store.recordTerminalRenderGridDelivery(try Self.renderGridFrame(
            surfaceID: surfaceID,
            seq: 1,
            activeScreen: .alternate
        ))

        try await confirmation("same active screen does not notify", expectedCount: 0) { didChange in
            withObservationTracking {
                _ = store.isAlternateScreen(surfaceID: surfaceID)
            } onChange: {
                didChange()
            }
            store.recordTerminalRenderGridDelivery(try Self.renderGridFrame(
                surfaceID: surfaceID,
                seq: 2,
                activeScreen: .alternate
            ))
        }

        try await confirmation("different active screen notifies") { didChange in
            withObservationTracking {
                _ = store.isAlternateScreen(surfaceID: surfaceID)
            } onChange: {
                didChange()
            }
            store.recordTerminalRenderGridDelivery(try Self.renderGridFrame(
                surfaceID: surfaceID,
                seq: 3,
                activeScreen: .primary
            ))
        }
    }

    private static func makeStore(defaults: UserDefaults) -> MobileShellComposite {
        return MobileShellComposite(
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            pairingHintDefaults: defaults
        )
    }

    private static func renderGridFrame(
        surfaceID: String,
        seq: UInt64,
        activeScreen: MobileTerminalRenderGridFrame.Screen
    ) throws -> MobileTerminalRenderGridFrame {
        var encodedFrame = try renderGridEventFrame(
            surfaceID: surfaceID,
            seq: seq,
            text: "frame",
            activeScreen: activeScreen
        )
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &encodedFrame)
        let payload = try #require(payloads.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let renderGridObject = try #require(envelope["payload"])
        return try MobileTerminalRenderGridFrame.decodeJSONObject(renderGridObject)
    }
}
