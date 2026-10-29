import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextDevices
import CmuxNextPages
@testable import CmuxNextServer
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The one-line join's consent gate on this Mac (contract §5): a joined Mac's Screen sharing and
/// Control stay off until the person turns one on. An on needs a line acpmux proved as the person
/// (Full access's rule), and so does an off, which needs no click; the first refused request shows the sheet once;
/// page script alone never turns one on.
@MainActor @Suite(.serialized) struct JoinConsentTests {
    final class FakeLine: JoinConsentLine {
        let isPerson: Bool
        let supportsConsent: Bool
        let takes: Bool
        let owner: Fake
        var writes: [String] = []
        var closed = false
        init(_ owner: Fake) {
            self.owner = owner
            isPerson = owner.person
            supportsConsent = owner.capable
            takes = owner.takes
        }
        func read() async -> JoinConsentRecord? { owner.record }
        func set(_ surface: JoinConsentSurface, granted: Bool) async -> Bool {
            writes.append("\(surface.rawValue) \(granted)")
            // acpmux takes a grant and a revoke only from the person's connection.
            guard takes, isPerson else { return false }
            if surface == .screen { owner.record.screen = granted } else { owner.record.control = granted }
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
        /// acpmux announces `machine-consent-v1`.
        var capable = true
        /// acpmux takes the write.
        var takes = true
        /// acpmux's consent record.
        var record = JoinConsentRecord()
        var enabled = true
        var askShown = false
        var lines: [FakeLine] = []

        func services() -> JoinConsentServices {
            JoinConsentServices(
                status: { [self] in status },
                openLine: { [self] in
                    let line = FakeLine(self)
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
        #expect(fake.lines.allSatisfy { $0.closed })
    }

    @Test func thePersonTurnsASwitchOnAndOffAndAnotherLineTurnsNeither() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        #expect(await model.set(.screen, on: true) == nil)
        fake.person = false
        #expect(await model.set(.screen, on: false) == JoinConsentStrings.offFailed, "acpmux takes a revoke only from the person")
        #expect(model.consent?.screen == true)
        fake.person = true
        #expect(await model.set(.screen, on: false) == nil)
        #expect(fake.writes == ["screen true", "screen false", "screen false"])
        #expect(model.lastError == nil && model.consent?.screen == false)
    }

    @Test func anOnNeedsAJoinedUnrevokedMacWithTheLabsSwitchOnButOffAlwaysGoesThrough() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        fake.enabled = false
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        fake.enabled = true
        fake.status = JoinStatus(credentialPresent: true, machineId: "m_1", revoked: true)
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        #expect(!model.shown, "a revoked join shows no switches")
        fake.status = JoinStatus(credentialPresent: false)
        #expect(await model.set(.control, on: true) == JoinConsentStrings.onFailed)
        #expect(fake.writes.isEmpty, "no on reached acpmux")
        fake.enabled = false
        #expect(await model.set(.screen, on: false) == nil)
        #expect(fake.writes == ["screen false"])
    }

    @Test func anAllowThatDoesNotTakeKeepsTheSheetUpWithTheReason() async {
        let fake = Fake()
        fake.takes = false
        let model = JoinConsentModel(services: fake.services())
        let shown = Recorder()
        model.present = { shown.values.append("\($0)") }
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        #expect(await model.answer(allow: true) == JoinConsentStrings.onFailed)
        #expect(model.ask != nil && model.askError == JoinConsentStrings.onFailed)
        #expect(shown.values == ["true", "true"])
        #expect(await model.answer(allow: false) == nil)
        #expect(model.ask == nil && model.askError == nil && shown.values.last == "false")
    }

    @Test func turningTheLabsSwitchOffClosesAnOpenSheet() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        fake.enabled = false
        await model.refresh()
        #expect(model.ask == nil)
        #expect(await model.answer(allow: true) == nil)
        #expect(fake.writes.isEmpty)
    }

    @Test func anOlderStatusReadThatAnswersLateNeverOverwritesANewerOne() async {
        let gate = Gate()
        var reads = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: {
                reads += 1
                if reads == 1 {
                    await gate.wait()
                    return JoinStatus(credentialPresent: true, name: "old")
                }
                return JoinStatus(credentialPresent: true, name: "new")
            },
            openLine: { nil }, enabled: { true }, askShown: { false }, markAskShown: {}))
        let first = Task { await model.refresh() }
        for _ in 0..<1000 where reads < 1 { await Task.yield() }
        #expect(reads == 1, "the first read never started")
        guard reads == 1 else { gate.open(); return }
        await model.refresh()
        gate.open()
        await first.value
        #expect(model.status?.name == "new")
    }

    @MainActor final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// sr2's ruling: an acpmux without `machine-consent-v1` has granted nothing. Its switches stay off with
    /// the reason, an on writes nothing, and Mac Screen (which the app serves) is refused with the sheet.
    @Test func aDaemonWithoutConsentSupportGrantsNothingAndMacScreenIsRefusedWithTheSheet() async throws {
        let fake = Fake()
        fake.capable = false
        fake.record = JoinConsentRecord(screen: true, control: true)
        let model = JoinConsentModel(services: fake.services())
        let shown = Recorder()
        model.present = { shown.values.append("\($0)") }
        await model.refresh()
        #expect(model.consentSupported == false && model.consent == nil, "a record it cannot vouch for is not read")
        let page = try #require(try JSONSerialization.jsonObject(with: try #require(model.pageData())) as? [String: Any])
        #expect((page["switches"] as? [[String: Any]])?.map { $0["on"] as? Bool } == [false, false])
        #expect(page["error"] as? String == JoinConsentStrings.unsupported)
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.unsupported)
        #expect(fake.writes.isEmpty)
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")))
        #expect(model.ask == JoinConsentRefusal(requester: "Studio", surface: .screen) && shown.values == ["true"])
        // Not joined changes nothing without consent support: never a fallback to allowing.
        fake.status = JoinStatus(credentialPresent: false)
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")))
        #expect(!model.permitsMacScreen(control: false))
    }

    @Test func macScreenServesOnlyWhatThePersonAllowedOnceJoinedAndNothingChangesWithTheLabsSwitchOff() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        #expect(!model.permitsMacScreen(control: false), "nothing read yet: refused")
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")))
        #expect(model.ask == JoinConsentRefusal(requester: "Studio", surface: .screen))
        #expect(await model.answer(allow: true) == nil)
        #expect(await model.allowsMacScreen(control: false, requester: "Studio"), "View Only needs Screen sharing")
        #expect(!(await model.allowsMacScreen(control: true, requester: "Studio")), "Full Control needs Control too")
        #expect(await model.set(.control, on: true) == nil)
        #expect(await model.allowsMacScreen(control: true, requester: "Studio"))
        fake.status = JoinStatus(credentialPresent: false)
        fake.record = JoinConsentRecord()
        #expect(await model.allowsMacScreen(control: true, requester: "Studio"), "a Mac that is not joined serves as before")
        fake.enabled = false
        fake.status = nil
        #expect(await model.allowsMacScreen(control: true, requester: "Studio"), "the Labs switch off changes nothing")
    }

    /// A join made since the last read (the CLI, with the app in the background) counts at once: each
    /// request reads fresh, and acpmux's `consentRequired` wins over the join status.
    @Test func aJoinSinceTheLastReadIsReadWhenTheRequestArrives() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        let model = JoinConsentModel(services: fake.services())
        #expect(await model.allowsMacScreen(control: false, requester: "Studio"))
        #expect(model.permitsMacScreen(control: false))
        fake.status = JoinStatus(credentialPresent: true, machineId: "m_1")
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")), "joined meanwhile: refused")
        fake.status = JoinStatus(credentialPresent: false)
        fake.record.consentRequired = true
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")), "acpmux says joined")
        let changes = Recorder()
        model.changed = { changes.values.append("\(model.permitsMacScreen(control: false))") }
        fake.record.consentRequired = false
        await model.refresh()
        #expect(changes.values == ["true"], "each read tells the app, which stops a session no longer allowed")
    }

    #if DEBUG
    @Test func aCaptureFixtureNeverAuthorizesALiveMacScreenSession() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        let model = JoinConsentModel(services: fake.services())
        let ticket = SessionTicket(sessionId: "s1", ticket: "a.b.c", signalURL: URL(string: "wss://hub.invalid/v1/sessions/s1/ws")!,
                                   ice: [], peer: .init(id: "v1", name: "Studio", signingKey: "key"), role: .host, scope: .view)
        #expect(await model.macScreenGate(ticket), "an unjoined Mac serves as before")
        DebugJoinConsent.status = JoinStatus(credentialPresent: false)
        defer { DebugJoinConsent.status = nil }
        #expect(!(await model.macScreenGate(ticket)))
        #expect(!model.macScreenPermits(.view))
    }
    #endif

    @Test func aRefusalAcpmuxRecordedShowsTheSheetOnceUnlessThatSurfaceIsOn() async {
        let fake = Fake()
        fake.record = JoinConsentRecord(screen: false, control: true, lastRefusal: .control)
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        #expect(model.ask == nil, "control is already on")
        fake.record.lastRefusal = .screen
        await model.refresh()
        #expect(model.ask == JoinConsentRefusal(requester: JoinConsentStrings.teamMachine, surface: .screen))
        #expect(await model.answer(allow: false) == nil)
        await model.refresh()
        #expect(model.ask == nil && fake.writes.isEmpty, "once")
    }

    @Test func noAcpmuxIsAFailureNeverAnOn() async {
        let model = JoinConsentModel(services: JoinConsentServices(status: { JoinStatus(credentialPresent: true) }, openLine: { nil },
                                                                   enabled: { true }, askShown: { false }, markAskShown: {}))
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        #expect(await model.set(.screen, on: false) == JoinConsentStrings.offFailed)
    }

    @Test func theRecordReadsOnlyGrantedAsOnAndTheSwitchesShowOnlyWhenJoinedAndTheLabsSwitchIsOn() async throws {
        let status = try #require(JoinStatus.parse(Data(#"{"credentialPresent":true,"machineId":"m_1","teamId":"t_1","revoked":false,"consent":{"screen":"granted"}}"#.utf8)))
        #expect(status.credentialPresent && status.machineId == "m_1")
        let words = try #require(JoinConsentRecord.parse(["consent": ["screen": "granted", "control": "none", "grantedAt": 1] as [String: Any], "lastRefusal": NSNull()]))
        #expect(words == JoinConsentRecord(screen: true, control: false))
        let other = try #require(JoinConsentRecord.parse(["consent": ["screen": true, "control": "yes"] as [String: Any],
                                                          "lastRefusal": ["event": "consent_refused", "code": "consent_required", "surface": "control", "at": 1] as [String: Any]]))
        #expect(other == JoinConsentRecord(screen: false, control: false, lastRefusal: .control), "only the word granted is on")
        #expect(JoinConsentRecord.parse([:]) == nil)

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
        do {
            _ = try await page.call("cmux.settings.devices.join_consent", params: ["surface": "webcam", "on": true],
                                    context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 10))
            Issue.record("an unknown surface was taken")
        } catch let error as PageError {
            #expect(error.code != PageNativeOp.userOnlyCode, "refused for its surface, not its gesture")
        }
        #expect(sets.values == ["screen false", "screen true"])
    }
}
