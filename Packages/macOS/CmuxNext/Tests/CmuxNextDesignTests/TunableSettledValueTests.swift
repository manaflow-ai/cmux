import CmuxNextDesignTokens
import Foundation
import Testing

/// `Tunable.settledValue`: the override, else the default, for a read at a launch step that cannot wait for the
/// store's main-actor load of the Debug Settings file (Chromium's launch switches, `CEFSwitches.current`).
///
/// A plain `value` read races that load and answers the default, which for a launch-time switch is worse than a
/// wrong value: the process launches without the switch while the store later reports the setting on, so an A/B
/// labels an arm by what it stored rather than by what it launched with — the trap cmux#45709 shipped.
@MainActor @Suite(.serialized) struct TunableSettledValueTests {
    private static let section = TunableSection(id: "settledValueTest", title: "Settled value test", symbol: "gauge", order: 9_999)
    private static let toggle = Tunable<Bool>.toggle("settledValueTest.toggle", section, "Toggle",
                                                     help: "A launch-time toggle, for this test only.", default: false)

    /// A store whose file read is pending, with `values` written to its file. Nothing awaits here, so on the main
    /// actor the load cannot land: the state every launch-time read happens in.
    private func loadingStore(_ values: String) throws -> TunableStore {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "settled-\(UUID().uuidString).json")
        try Data("{\"version\": 1, \"values\": {\(values)}}".utf8).write(to: file)
        let store = TunableStore()
        store.register([Self.toggle.descriptor])
        store.activate(file: file)
        return store
    }

    /// The file says on. While its read is pending `value` answers the default; `settledValue` reads the file and
    /// answers what the launch step must pass Chromium, and leaves that value in the store, so what the process
    /// launched with is what the store reports from then on.
    @Test func aLaunchReadGetsTheFilesValueWhileTheStoreLoadIsPending() throws {
        let store = try loadingStore(#""settledValueTest.toggle": true"#)
        #expect(Self.toggle.value(in: store) == false, "the pending load answered the file: this test proves nothing")
        #expect(Self.toggle.settledValue(in: store) == true)
        #expect(Self.toggle.value(in: store) == true, "the settled read did not leave its value in the store")
    }

    /// With no value for the key, a settled read is the default, and it does not invent an override.
    @Test func withNoValueInTheFileASettledReadIsTheDefault() throws {
        let store = try loadingStore(#""other.key": true"#)
        #expect(Self.toggle.settledValue(in: store) == false)
        #expect(Self.toggle.override(in: store) == nil)
    }

    /// A store that never activated (Release and RC, where Debug Settings are inert) answers the default without
    /// reading anything.
    @Test func anInactiveStoreAnswersTheDefault() {
        let store = TunableStore()
        store.register([Self.toggle.descriptor])
        #expect(Self.toggle.settledValue(in: store) == false)
        #expect(Self.toggle.value(in: store) == false)
    }

    /// Once the load lands, both reads agree: the settled read is a head start, not a second source of truth.
    @Test func theTwoReadsAgreeOnceTheLoadLands() async throws {
        let store = try loadingStore(#""settledValueTest.toggle": true"#)
        let deadline = Date().addingTimeInterval(5)
        while Self.toggle.override(in: store) == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(Self.toggle.override(in: store) == true, "the store's own read of the file never landed")
        #expect(Self.toggle.value(in: store) == Self.toggle.settledValue(in: store))
    }
}
