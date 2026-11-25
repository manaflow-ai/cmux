#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesignTokens
import CmuxNextSettings
import Testing

/// A tunable's read cadence, and what `debug.tunables` says about it.
///
/// cmux#45709 shipped a switch whose two gates made it nil, so an A/B measured the same thing twice
/// and reported it as off against on. The same shape bit the bench harness again with
/// `browserPage.noFrameRateLimit`: Chromium reads its command line once, so a live `set` stores the
/// value and the running process keeps the old one, while `set` answered as if the change had
/// landed. A descriptor now declares when the app reads it, and every row says whether the stored
/// value is the one this process uses, so a harness cannot read success into a change that did nothing.
@MainActor @Suite(.serialized)
struct TunableReadCadenceTests {
    private static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    private static func call(_ params: [String: CmuxNextSettings.JSONValue], _ store: TunableStore,
                             _ services: AppServices,
                             _ catalog: [TunableDescriptor] = TunableCatalog.all) -> CmuxNextSettings.JSONValue {
        DebugTunables.handle(params, services: services, store: store, catalog: catalog)
    }

    /// A launch-time toggle, as `browserPage.noFrameRateLimit` declares itself: no shipped tunable is
    /// read at launch yet, so the launch row is driven through a catalog of this one.
    private static let launchRead = Tunable<Bool>.toggle(
        "test.launchRead", BrowserPageTunables.section, "Launch read",
        help: "Read once while the app starts.", default: false, readCadence: .launch)

    /// Live is the default: nothing declares a cadence unless it is read at launch.
    @Test func aTunableIsLiveUnlessItSaysOtherwise() {
        #expect(BrowserPageTunables.uiPointer.descriptor.readCadence == .live)
        #expect(Self.launchRead.descriptor.readCadence == .launch)
    }

    /// A live key's row says the value applies, so an A/B arm may set it and measure at once.
    @Test func aLiveRowSaysItApplies() {
        let services = Self.services(), store = TunableStore()
        _ = Self.call(["action": "activate"], store, services)
        let row = Self.call(["action": "set", "key": .string(BrowserPageTunables.uiPointer.key), "value": true], store, services)
        #expect(row["read_cadence"]?.stringValue == "live")
        #expect(row["applies"]?.boolValue == true)
        #expect(row["applies_why"] == nil)
    }

    /// A launch-time key's row says the stored value is not the one this process uses, and why: an
    /// A/B over it takes one launch per arm, not a `set` between arms.
    @Test func aLaunchTimeRowSaysItNeedsARelaunch() {
        let services = Self.services(), store = TunableStore()
        let catalog = [Self.launchRead.descriptor]
        _ = Self.call(["action": "activate"], store, services, catalog)
        let row = Self.call(["action": "set", "key": "test.launchRead", "value": true], store, services, catalog)
        #expect(row["read_cadence"]?.stringValue == "launch")
        #expect(row["applies"]?.boolValue == false)
        #expect(row["applies_why"]?.stringValue?.contains("relaunch") == true)
        // The store still took the value: the next launch is the one that uses it.
        #expect(row["value"]?.boolValue == true)
        #expect(Self.launchRead.value(in: store) == true)
    }

    /// Nothing has read the key this launch: the row says so, rather than claiming the value is in
    /// use, and carries no `launch_value` to measure against.
    @Test func anUnreadLaunchKeySaysNothingHasReadIt() {
        let services = Self.services(), store = TunableStore()
        let catalog = [Self.launchRead.descriptor]
        _ = Self.call(["action": "activate"], store, services, catalog)
        let row = Self.call(["action": "get", "key": "test.launchRead"], store, services, catalog)
        #expect(row["applies"]?.boolValue == false)
        #expect(row["applies_why"]?.stringValue?.contains("nothing has read it") == true)
        #expect(row["launch_value"] == nil)
    }

    /// A bench build reads the key at launch with the store still inactive, then activates it. The
    /// launch ran the default, so a value stored afterwards does not apply to this launch — and the
    /// row says so instead of having no record of the read at all.
    @Test func aLaunchReadBeforeActivateIsStillRecorded() {
        let services = Self.services(), store = TunableStore()
        let catalog = [Self.launchRead.descriptor]
        #expect(store.settledOverride("test.launchRead") == nil)   // the launch step, store inactive
        #expect(store.wasReadAtLaunch("test.launchRead") == true)

        _ = Self.call(["action": "activate"], store, services, catalog)
        let launchArm = Self.call(["action": "get", "key": "test.launchRead"], store, services, catalog)
        #expect(launchArm["applies"]?.boolValue == true)
        #expect(launchArm["launch_value"]?.boolValue == false)

        let changed = Self.call(["action": "set", "key": "test.launchRead", "value": true], store, services, catalog)
        #expect(changed["applies"]?.boolValue == false)
        #expect(changed["launch_value"]?.boolValue == false)
    }

    /// The arm the harness launched with: a launch-time key whose stored value is the one this
    /// process read at launch applies, and the row carries that read as `launch_value`. Reporting
    /// the cadence alone would call this correct arm unapplied.
    @Test func aLaunchKeyMatchingWhatThisProcessReadApplies() {
        let services = Self.services(), store = TunableStore()
        let catalog = [Self.launchRead.descriptor]
        _ = Self.call(["action": "activate"], store, services, catalog)
        // The launch step reads it, as CEFSwitches does for its frame-pacing switch (#48152 gives
        // that read a typed `Tunable.settledValue`; the store call under it is the same one).
        #expect(store.settledOverride("test.launchRead") == nil)

        let launchArm = Self.call(["action": "get", "key": "test.launchRead"], store, services, catalog)
        #expect(launchArm["applies"]?.boolValue == true)
        #expect(launchArm["applies_why"] == nil)
        #expect(launchArm["launch_value"]?.boolValue == false)

        // A `set` away from it does not apply to this launch, and names the value in use.
        let changed = Self.call(["action": "set", "key": "test.launchRead", "value": true], store, services, catalog)
        #expect(changed["applies"]?.boolValue == false)
        #expect(changed["launch_value"]?.boolValue == false)
        #expect(changed["applies_why"]?.stringValue?.contains("launch_value") == true)

        // Set back to the launch value: this launch is using it again.
        let restored = Self.call(["action": "set", "key": "test.launchRead", "value": false], store, services, catalog)
        #expect(restored["applies"]?.boolValue == true)
        #expect(restored["applies_why"] == nil)
    }
}
#endif
