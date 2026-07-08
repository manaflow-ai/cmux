import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
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

    @Test func dismissedFlagPersistsAcrossStoreInstances() {
        let suiteName = "altscreen-dismissed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstState = AltScreenNoticeState(defaults: defaults)
        #expect(firstState.dismissed == false)

        firstState.dismiss()
        #expect(firstState.dismissed)

        let secondState = AltScreenNoticeState(defaults: defaults)
        #expect(secondState.dismissed)
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
