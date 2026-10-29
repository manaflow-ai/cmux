import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextServer
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The one-line join's consent gate on this Mac (contract §5): a joined Mac's Screen sharing and
/// Control stay off until the person turns one on. An on needs a line acpmux proved as the person
/// (Full access's rule); off works from any line; the first refused request shows the sheet once;
/// page script alone never turns one on.
@MainActor @Suite(.serialized) struct JoinConsentTests {
    final class FakeLine: JoinConsentLine {
        let isPerson: Bool
        var writes: [String] = []
        var closed = false
        init(isPerson: Bool) { self.isPerson = isPerson }
        func set(_ surface: JoinConsentSurface, on: Bool) async -> Bool {
            writes.append("\(surface.rawValue) \(on)")
            return true
        }
        func close() { closed = true }
    }

    final class Recorder {
        var values: [String] = []
    }

    final class Fake {
        var status: JoinStatus? = JoinStatus(credentialPresent: true, machineId: "m_1", teamId: "t_1", teamName: "Example Team", name: "studio")
        var person = true
        var enabled = true
        var askShown = false
        var lines: [FakeLine] = []

        func services() -> JoinConsentServices {
            JoinConsentServices(
                status: { [self] in status },
                openLine: { [self] in
                    let line = FakeLine(isPerson: person)
                    lines.append(line)
                    return line
                },
                enabled: { [self] in enabled },
                askShown: { [self] in askShown },
                markAskShown: { [self] in askShown = true })
        }

        var writes: [String] { lines.flatMap(\.writes) }
    }

    @Test func aLineThatIsNotThePersonTurnsNeitherSwitchOn() async {
        let fake = Fake()
        fake.person = false
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        for surface in JoinConsentSurface.allCases {
            let error = await model.set(surface, on: true)
            #expect(error == JoinConsentStrings.onFailed)
        }
        #expect(fake.writes.isEmpty, "no on reached acpmux")
        #expect(fake.lines.allSatisfy(\.closed))
    }

    @Test func thePersonTurnsASwitchOnAndAnyLineTurnsItOff() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        #expect(await model.set(.screen, on: true) == nil)
        fake.person = false
        #expect(await model.set(.screen, on: false) == nil)
        #expect(await model.set(.control, on: false) == nil)
        #expect(fake.writes == ["screen true", "screen false", "control false"])
        #expect(model.lastError == nil)
    }

    @Test func noAcpmuxIsAFailureNeverAnOn() async {
        let model = JoinConsentModel(services: JoinConsentServices(status: { nil }, openLine: { nil }, enabled: { true },
                                                                   askShown: { false }, markAskShown: {}))
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        #expect(await model.set(.screen, on: false) == JoinConsentStrings.offFailed)
    }

    @Test func statusReadsBoolsOrWordsAndTheSwitchesShowOnlyWhenJoinedAndTheLabsSwitchIsOn() async throws {
        let words = try #require(JoinStatus.parse(Data(#"{"credentialPresent":true,"machineId":"m_1","teamId":"t_1","revoked":false,"consent":{"screen":"granted","control":"none"}}"#.utf8)))
        #expect(words.screen && !words.control)
        let bools = try #require(JoinStatus.parse(Data(#"{"credentialPresent":true,"consent":{"screen":false,"control":true,"grantedAt":"2026-10-29T03:30:00Z"}}"#.utf8)))
        #expect(!bools.screen && bools.control)
        let bare = try #require(JoinStatus.parse(Data(#"{"credentialPresent":false}"#.utf8)))
        #expect(!bare.screen && !bare.control && !bare.credentialPresent)

        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        #expect(model.shown)
        let page = try #require(model.pageData())
        let json = try #require(try JSONSerialization.jsonObject(with: page) as? [String: Any])
        #expect(json["joined"] as? String == "Joined to Example Team as studio")
        #expect((json["switches"] as? [[String: Any]])?.map { $0["on"] as? Bool } == [false, false], "both off by default")
        fake.enabled = false
        await model.refresh()
        #expect(!model.shown && model.pageData() == nil)
        fake.enabled = true
        fake.status = JoinStatus(credentialPresent: false)
        await model.refresh()
        #expect(!model.shown)
    }

    @Test func theFirstRefusedRequestShowsTheSheetOnceAndAllowWritesThroughThePerson() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        let shown = Recorder()
        model.present = { shown.values.append("\($0)") }
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        #expect(model.ask == JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        #expect(shown.values == ["true"])
        model.refused(JoinConsentRefusal(requester: "other", surface: .control))
        #expect(model.ask?.requester == "lane-vm-3", "a second refusal while it shows changes nothing")
        #expect(await model.answer(allow: true) == nil)
        #expect(model.ask == nil && shown.values == ["true", "false"])
        #expect(fake.writes == ["screen true"])
        // Once: a later refusal never shows it again, even after a relaunch reads the kept bit.
        let again = JoinConsentModel(services: fake.services())
        again.refused(JoinConsentRefusal(requester: "lane-vm-4", surface: .screen))
        #expect(again.ask == nil)
    }

    @Test func denyWritesNothingAndTheLabsSwitchOffShowsNoSheet() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .control))
        #expect(await model.answer(allow: false) == nil)
        #expect(fake.writes.isEmpty)
        let off = Fake()
        off.enabled = false
        let quiet = JoinConsentModel(services: off.services())
        quiet.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        #expect(quiet.ask == nil && !off.askShown)
    }

    @Test func theSheetDrawsItsQuestionAndBothAnswers() async throws {
        _ = NSApplication.shared
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        let view = JoinConsentAskView(model: model)
        let ids = AddDeviceShotsTests.identifiers(view)
        #expect(ids.contains("cmux.joinConsentAsk.allow") && ids.contains("cmux.joinConsentAsk.deny"))
        let image = try AddMachineShotsTests.render(view)
        #expect(image.size.width >= 300 && image.size.height >= 80)
    }

    @Test func pageScriptAloneNeverTurnsAConsentOnAndOffNeedsNoClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-join-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        let sets = Recorder()
        page.setJoinConsent = { surface, on in sets.values.append("\(surface) \(on)"); return nil }
        let on: JSONValue = ["surface": "screen", "on": true], off: JSONValue = ["surface": "screen", "on": false]
        do {
            _ = try await page.call("cmux.settings.devices.join_consent", params: on, context: PageCallContext(page: PageDescriptor.settings.id))
            Issue.record("page script turned it on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        _ = try await page.call("cmux.settings.devices.join_consent", params: off, context: PageCallContext(page: PageDescriptor.settings.id))
        let click = PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 9)
        _ = try await page.call("cmux.settings.devices.join_consent", params: on, context: click)
        do {
            _ = try await page.call("cmux.settings.devices.join_consent", params: ["surface": "control", "on": true], context: click)
            Issue.record("one click turned two on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(sets.values == ["screen false", "screen true"])
    }
}
