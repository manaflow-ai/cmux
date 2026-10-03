#if DEBUG
import AppKit
import CmuxNextHome
import CmuxNextSettings

/// DEBUG ONLY: `debug.home_native_fixture.open` opens the native Home
/// transcript (`HomeNativeTranscriptView`) over the mock owner's fixture
/// data as an internal page tab of the active window, for screenshots
/// (`debug.window_snapshot`) and dogfood before the real Home wiring.
/// Compiled out of Release with this whole file.
extension InternalPageID {
    static let homeNativeFixture = InternalPageID(rawValue: "home-native-fixture")
}

@MainActor
final class DebugHomeNativeFixture: InternalPageProvider {
    private var fixtures: [String: HomeNativeFixture] = [:]

    var page: InternalPageID { .homeNativeFixture }
    var title: String { HomeNativeFixture.title }
    var symbol: String { "bubble.left.and.bubble.right" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let fixture = HomeNativeFixture()
        fixtures[key] = fixture
        return fixture.container
    }

    func tabClosed(_ key: String) {
        fixtures.removeValue(forKey: key)?.close()
    }

    static func open(services: AppServices) -> JSONValue {
        if services.pages.provider(.homeNativeFixture) == nil { services.pages.register(DebugHomeNativeFixture()) }
        let view = services.pages.show(.homeNativeFixture, in: services.windows.active, focus: false)
        return .object(["ok": .bool(view != nil), "page": .string(InternalPageID.homeNativeFixture.rawValue)])
    }
}
#endif
