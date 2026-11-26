@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The customize doctor's app-wide notice: each run is `cmux --json customize doctor --announce`,
/// a non-null `announce` with `customize.doctorNotice` on is one toast, and a burst of loads is
/// one run in flight plus one after it.
@MainActor @Suite struct CustomizeDoctorNoticeTests {
    typealias Runs = SettingsCustomizeLibraryRuns

    static func answer(_ announce: String?) -> (Int32, Data, Data) {
        let value = announce.map { "\"\($0)\"" } ?? "null"
        return (0, Data(#"{"doctor":{"findings":[],"line":null,"announce":\#(value)}}"#.utf8), Data())
    }

    func makeNotice(_ runs: Runs, shown: @escaping @MainActor (String) -> Void) -> CustomizeDoctorNotice {
        CustomizeDoctorNotice(cli: { URL(fileURLWithPath: "/bin/cmux") },
                              settingsFile: { URL(fileURLWithPath: "/tmp/cmux-next.json") },
                              runCLI: { _, arguments, environment in
                                  runs.arguments.append(arguments)
                                  runs.configFiles.append(environment["CMUX_NEXT_CONFIG_FILE"])
                                  return runs.answer
                              },
                              untilWindow: {}, present: shown)
    }

    /// Off by default (Leo 2026-11-25: "make it stop showing the customization not applied/reviewd
    /// and shit popup tosts"): with the key unset a new finding runs nothing and pops nothing.
    @Test func theNoticeIsOffByDefaultSoAFindingPopsNoToast() async {
        #expect(CmuxConfigSnapshot.customizeDoctorNoticeDefault == false)
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).customizeDoctorNotice == false)
        let on = JSONValue.object(["customize": .object(["doctorNotice": .bool(true)])])
        #expect(CmuxConfigSnapshot.parse(on, validDensities: [], validMetrics: []).customizeDoctorNotice == true)
        let runs = Runs()
        runs.answer = Self.answer("pr-1 is still on")
        var shown: [String] = []
        let notice = makeNotice(runs) { shown.append($0) }
        notice.request()
        await notice.running?.value
        #expect(runs.arguments.isEmpty)
        #expect(shown.isEmpty)
    }

    @Test func theDecisionIsTheAnnounceLineWhenTheNoticeIsOn() {
        let announced = JSONValue.object(["doctor": .object(["announce": .string("1 customization problem: pr-1 is still on")])])
        #expect(CustomizeDoctorNotice.announcement(announced, isOn: true) == "1 customization problem: pr-1 is still on")
        #expect(CustomizeDoctorNotice.announcement(announced, isOn: false) == nil)
        #expect(CustomizeDoctorNotice.announcement(.object(["doctor": .object(["announce": .null])]), isOn: true) == nil)
        #expect(CustomizeDoctorNotice.announcement(.object(["doctor": .object(["announce": .string("  ")])]), isOn: true) == nil)
        #expect(CustomizeDoctorNotice.announcement(.object([:]), isOn: true) == nil)
    }

    @Test func aNewFindingIsOneToastFromTheAnnounceRun() async {
        let runs = Runs()
        runs.answer = Self.answer("pr-1 is still on")
        var shown: [String] = []
        let notice = makeNotice(runs) { shown.append($0) }
        notice.isOn = { true }
        notice.request()
        await notice.running?.value
        #expect(runs.arguments == [["--json", "customize", "doctor", "--announce"]])
        #expect(runs.configFiles == ["/tmp/cmux-next.json"])
        #expect(shown == ["pr-1 is still on"])
    }

    @Test func nothingNewOrAFailedRunShowsNothing() async {
        let runs = Runs()
        runs.answer = Self.answer(nil)
        var shown: [String] = []
        let notice = makeNotice(runs) { shown.append($0) }
        notice.isOn = { true }
        notice.request()
        await notice.running?.value
        runs.answer = (1, Data(#"{"doctor":{"announce":"stale"}}"#.utf8), Data(#"{"code":"x","message":"y"}"#.utf8))
        notice.request()
        await notice.running?.value
        #expect(runs.arguments.count == 2)
        #expect(shown.isEmpty)
    }

    /// Off runs nothing, so the CLI marks nothing seen that the person was never told.
    @Test func theSettingOffRunsNothingAndShowsNothing() async {
        let runs = Runs()
        runs.answer = Self.answer("pr-1 is still on")
        var shown: [String] = []
        let notice = makeNotice(runs) { shown.append($0) }
        notice.isOn = { false }
        notice.request()
        await notice.running?.value
        #expect(runs.arguments.isEmpty)
        #expect(shown.isEmpty)
    }

    /// Loads that come before the run starts are that run (it reads the files after them).
    @Test func aBurstOfLoadsIsOneRun() async {
        let runs = Runs()
        runs.answer = Self.answer(nil)
        let notice = makeNotice(runs) { _ in }
        notice.isOn = { true }
        notice.request()
        notice.request()
        notice.request()
        notice.request()
        await notice.running?.value
        #expect(runs.arguments.count == 1)
        #expect(notice.running == nil)
    }

    /// Loads that come while a run is in flight make exactly one more run after it.
    @Test func loadsDuringARunMakeOneRunAfterIt() async {
        let runs = Runs()
        runs.answer = Self.answer(nil)
        let loads = DuringRunLoads()
        let notice = CustomizeDoctorNotice(cli: { URL(fileURLWithPath: "/bin/cmux") }, settingsFile: { nil },
                                           runCLI: { _, arguments, _ in
                                               runs.arguments.append(arguments)
                                               if runs.arguments.count == 1 { await loads.arrive(3) }
                                               return runs.answer
                                           },
                                           untilWindow: {}, present: { _ in })
        loads.notice = notice
        notice.isOn = { true }
        notice.request()
        await notice.running?.value
        // The first run's end started the second.
        await notice.running?.value
        #expect(runs.arguments.count == 2)
        #expect(notice.running == nil)
    }
}

/// Settings loads that arrive from inside the fake CLI's first run (main actor, the notice's own).
final class DuringRunLoads {
    weak var notice: CustomizeDoctorNotice?

    func arrive(_ count: Int) {
        for _ in 0..<count { notice?.request() }
    }
}
