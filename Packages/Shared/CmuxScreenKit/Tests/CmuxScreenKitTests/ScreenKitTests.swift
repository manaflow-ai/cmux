import CmuxScreenKit
import Foundation
import Testing

struct ScreenKitTests {
    @Test func preferencesSavedByOlderBuildsStillLoad() throws {
        let old = try JSONDecoder().decode(ScreenPreferences.self, from: Data(#"{"localCursor":false}"#.utf8))
        #expect(old.localCursor == false)
        #expect(old.fitToDisplay, "fitted mode is the default")
        #expect(old.showStats)
        #expect(old.quality == .auto)
        let unknownQuality = try JSONDecoder().decode(ScreenPreferences.self, from: Data(#"{"quality":"ultra"}"#.utf8))
        #expect(unknownQuality.quality == .auto)
    }

    @Test func preferencesRoundTrip() throws {
        let preferences = ScreenPreferences(localCursor: false, showStats: false, fitToDisplay: false, quality: .medium)
        let decoded = try JSONDecoder().decode(ScreenPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }

    @MainActor @Test func sessionsKnowTheirKind() throws {
        let stream = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let rfb = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac").link))
        #expect(ScreenSession(title: "Mac", pairing: stream).isStream)
        #expect(!ScreenSession(title: "Mac", pairing: rfb).isStream)
        let direct = ScreenSession(title: "Server", endpoint: VNCEndpoint(host: "192.168.1.2", port: 5900))
        #expect(!direct.isStream && !direct.isDemo)
        #expect(ScreenSession().isDemo)
        #expect(direct.phase == .connecting, "nothing runs until connect()")
        #expect(direct.id != ScreenSession().id)
    }

    @Test func orientationChoicesHaveTitlesAndSymbols() {
        #expect(OrientationLock.allCases.map(\.title) == ["Auto-Rotate", "Portrait", "Landscape"])
        #expect(OrientationLock.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}
