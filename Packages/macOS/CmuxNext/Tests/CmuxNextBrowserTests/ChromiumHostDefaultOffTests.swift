@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import Testing

/// Host mode (`browserHost.helper`) is on by default in DEV only: NIGHTLY,
/// RC and Release keep Chromium in process until task p01-process-104
/// (plans/cmux-next/chrome-parity/p01-process.md). DEV, staging and processes
/// outside a bundle share the DEV default, as `Feature.Channel` maps them.
@MainActor
@Suite struct ChromiumHostDefaultOffTests {
    /// Debug Settings as a DEV or NIGHTLY app holds them, with nothing changed.
    private static func activeStore(_ tunable: Tunable<Bool>) -> TunableStore {
        let store = TunableStore()
        store.register([tunable.descriptor])
        store.activate(file: nil)
        return store
    }

    @Test(arguments: [BuildIdentity.Kind.dev, .staging, .unbundled])
    func theHostIsOnByDefaultInDEV(kind: BuildIdentity.Kind) {
        let helper = BrowserHostTunables.declaration(for: kind)
        #expect(helper.defaultValue)
        #expect(helper.value(in: Self.activeStore(helper)))
    }

    @Test(arguments: [BuildIdentity.Kind.nightly, .rc, .release])
    func theHostIsOffByDefaultInNightlyRCAndRelease(kind: BuildIdentity.Kind) {
        let helper = BrowserHostTunables.declaration(for: kind)
        #expect(!helper.defaultValue)
        // Release and RC never activate the store: the default is the value.
        #expect(!helper.value(in: TunableStore()))
        #expect(!helper.value(in: Self.activeStore(helper)))
    }

    @Test func aDEVBuildCanTurnTheHostOff() {
        let helper = BrowserHostTunables.declaration(for: .dev)
        let store = Self.activeStore(helper)
        store.set(helper.key, .bool(false))
        #expect(!helper.value(in: store))
    }

    @Test func theAppsTunableTakesItsBuildsChannelDefault() {
        let helper = BrowserHostTunables.helper
        #expect(helper.key == "browserHost.helper")
        #expect(helper.defaultValue == BrowserHostTunables.helperDefault(for: BuildIdentity(bundle: .main).kind))
        #expect(BrowserHostTunables.all.map(\.key) == ["browserHost.helper"])
    }
}
