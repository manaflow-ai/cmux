import AppKit
import CmuxNextActions
import CmuxNextAgentPane
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
        /// Unowned: the fake keeps its lines (``Fake/lines``), not the other way round.
        unowned let owner: Fake
        var writes: [String] = []
        var closed = false
        init(_ owner: Fake) {
            self.owner = owner
            isPerson = owner.person
            supportsConsent = owner.capable
            takes = owner.takes
        }
        func read() async -> JoinConsentRecord? { owner.readFails ? nil : owner.record }
        func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? {
            // Between the model's last check and the line's write (the app's line writes on its own queue).
            await owner.beforeWrite?()
            // The write point: a grant's bytes go out only through its ticket, as the app's line writes them.
            let write = { self.writes.append("\(surface.rawValue) \(granted)") }
            guard ticket.map({ $0.write(write) }) ?? { write(); return true }() else { return nil }
            // acpmux takes a grant and a revoke only from the person's connection.
            guard takes, isPerson else { return nil }
            if surface == .screen { owner.record.screen = granted } else { owner.record.control = granted }
            return owner.record
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
        /// `_acpmux/machine_consent_get` fails.
        var readFails = false
        var enabled = true
        var askShown = false
        var lines: [FakeLine] = []
        /// The device owner's answer to a grant's confirm (Touch ID or the login password).
        var confirm = JoinConsentConfirm.confirmed
        /// Each confirm asked, by surface.
        var confirms: [String] = []
        /// Runs inside a write, after the model's checks and before the line writes its bytes.
        var beforeWrite: (@MainActor () async -> Void)?

        func services() -> JoinConsentServices {
            JoinConsentServices(
                status: { [self] in status },
                openLine: { [self] in
                    let line = FakeLine(self)
                    lines.append(line)
                    return line
                },
                enabled: { [self] in enabled },
                confirmOwner: { [self] surface in
                    confirms.append(surface.rawValue)
                    return confirm
                },
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
        let data = try #require(model.pageData())
        let page = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        fake.record = JoinConsentRecord(consentRequired: false)
        #expect(await model.allowsMacScreen(control: true, requester: "Studio"), "a Mac acpmux says is not joined serves as before")
        fake.enabled = false
        fake.status = nil
        #expect(await model.allowsMacScreen(control: true, requester: "Studio"), "the Labs switch off changes nothing")
    }

    /// A join made since the last read (the CLI, with the app in the background) counts at once: each
    /// request reads fresh. Only acpmux's own `consentRequired: false` lets a Mac serve as not joined:
    /// a join status that says so may be stale (it was read before acpmux's record), and so is no answer.
    @Test func aJoinSinceTheLastReadIsReadWhenTheRequestArrives() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        fake.record.consentRequired = false
        let model = JoinConsentModel(services: fake.services())
        #expect(await model.allowsMacScreen(control: false, requester: "Studio"))
        #expect(model.permitsMacScreen(control: false))
        fake.record.consentRequired = true
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")), "joined meanwhile: refused")
        fake.record.consentRequired = nil
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")),
                "a status read as not joined, with no word from acpmux, is refused")
        #expect(model.ask == nil, "and shows no sheet: as far as this Mac knows it has nothing to allow")
        let changes = Recorder()
        model.changed = { [weak model] in changes.values.append("\(model?.permitsMacScreen(control: false) ?? false)") }
        fake.record.consentRequired = false
        await model.refresh()
        #expect(changes.values == ["true"], "each read tells the app, which stops a session no longer allowed")
    }

    /// A request decides from its own read: a newer read still running when it answers, which keeps the
    /// older permissive state in place a moment longer, never lets it through.
    @Test func aRequestDecidesFromItsOwnReadNeverFromAnOlderPermissiveOne() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        fake.record.consentRequired = false
        let base = fake.services()
        let ticketRead = Gate(), laterRead = Gate()
        var reads = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: {
                reads += 1
                let read = reads
                if read == 2 { await ticketRead.wait() }
                if read == 3 { await laterRead.wait() }
                return await base.status()
            },
            openLine: base.openLine, enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown,
            markAskShown: base.markAskShown))
        await model.refresh()
        #expect(model.permitsMacScreen(control: false), "not joined: serves as before")
        fake.status = JoinStatus(credentialPresent: true, machineId: "m_1")
        fake.record.consentRequired = true
        let ticket = Task { await model.allowsMacScreen(control: false, requester: "Studio") }
        for _ in 0..<1000 where reads < 2 { await Task.yield() }
        let later = Task { await model.refresh() }
        for _ in 0..<1000 where reads < 3 { await Task.yield() }
        #expect(reads == 3, "both reads started")
        ticketRead.open()
        #expect(!(await ticket.value), "its own read says joined, with nothing allowed")
        laterRead.open()
        await later.value
        #expect(!model.permitsMacScreen(control: false))
    }

    /// A join between the status read and a consent read that fails: the stale "not joined" never allows.
    @Test func aFailedConsentReadAllowsNothingEvenOnAMacThatReadsNotJoined() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        fake.record.consentRequired = false
        let model = JoinConsentModel(services: fake.services())
        #expect(await model.allowsMacScreen(control: false, requester: "Studio"), "not joined, record read: as before")
        fake.readFails = true
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")))
        #expect(!model.permitsMacScreen(control: false))
    }

    /// Round 15: acpmux announces the consent capability and its join status says joined, but the record
    /// fails to read: the request is refused without the sheet (and the one-time sheet is still to come).
    /// Once the record reads, the refusal shows it. An acpmux without the capability shows it from the join
    /// status (``aDaemonWithoutConsentSupportGrantsNothingAndMacScreenIsRefusedWithTheSheet()``).
    @Test func anUnreadRecordRefusesWithoutTheSheet() async {
        let fake = Fake()
        fake.readFails = true
        let model = JoinConsentModel(services: fake.services())
        let shown = Recorder()
        model.present = { shown.values.append("\($0)") }
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")))
        #expect(model.ask == nil && shown.values.isEmpty && !fake.askShown)
        fake.readFails = false
        #expect(!(await model.allowsMacScreen(control: false, requester: "Studio")))
        #expect(model.ask == JoinConsentRefusal(requester: "Studio", surface: .screen) && shown.values == ["true"])
    }

    /// Round 15: the sheet asks for Screen sharing and the person turns Screen sharing on in Settings: the
    /// sheet closes. A grant of the other surface, or one that did not go through, leaves it up.
    @Test func aSettingsGrantOfTheSheetsSurfaceClosesTheSheet() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        let shown = Recorder()
        model.present = { shown.values.append("\($0)") }
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        #expect(await model.set(.control, on: true) == nil)
        #expect(model.ask != nil, "another surface's grant leaves it up")
        fake.confirm = .cancelled
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        #expect(model.ask != nil, "a grant that did not go through leaves it up")
        fake.confirm = .confirmed
        #expect(await model.set(.screen, on: true) == nil)
        #expect(model.ask == nil && model.askError == nil && shown.values == ["true", "false"])
    }

    /// A Deny pressed while an Allow is still writing does nothing: the Allow ends as it ends, and the
    /// sheet never closes over a grant still landing.
    @Test func aDenyWhileAnAllowWritesChangesNothing() async {
        let fake = Fake()
        let base = fake.services()
        let held = Gate()
        var hold = false, opened = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: base.status,
            openLine: {
                if hold {
                    opened += 1
                    await held.wait()
                }
                return await base.openLine()
            },
            enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown, markAskShown: base.markAskShown))
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "Studio", surface: .screen))
        hold = true
        let allow = Task { await model.answer(allow: true) }
        for _ in 0..<1000 where opened < 1 { await Task.yield() }
        #expect(model.writing)
        #expect(await model.answer(allow: false) == nil)
        #expect(model.ask != nil, "the Deny did not close the sheet over the Allow")
        hold = false
        held.open()
        #expect(await allow.value == nil)
        #expect(model.ask == nil && !model.writing && fake.writes == ["screen true"])
    }

    /// A ticket whose read said granted, answering after a revoke that acpmux already took, never serves.
    @Test func aGrantReadBeforeARevokeNeverAuthorizesAfterIt() async {
        let fake = Fake()
        fake.record.screen = true
        let base = fake.services()
        let held = Gate()
        var holdNext = false, reads = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: {
                reads += 1
                if holdNext {
                    holdNext = false
                    let answer = await base.status()
                    await held.wait()
                    return answer
                }
                return await base.status()
            },
            openLine: base.openLine, enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown,
            markAskShown: base.markAskShown))
        await model.refresh()
        #expect(model.permitsMacScreen(control: false))
        holdNext = true
        let ticket = Task { await model.allowsMacScreen(control: false, requester: "Studio") }
        for _ in 0..<1000 where reads < 2 { await Task.yield() }
        #expect(await model.set(.screen, on: false) == nil)
        fake.record.screen = true // the held read's acpmux answer, from before the revoke
        held.open()
        #expect(!(await ticket.value))
    }

    /// A revoke acpmux took stops a running session before the read that confirms it, even when that read
    /// hangs or a newer one replaces it.
    @Test func aRevokeCountsAtOnceBeforeItsConfirmingRead() async {
        let fake = Fake()
        fake.record = JoinConsentRecord(screen: true, control: true)
        let base = fake.services()
        let held = Gate()
        var holdReads = false
        let model = JoinConsentModel(services: JoinConsentServices(
            status: {
                if holdReads { await held.wait() }
                return await base.status()
            },
            openLine: base.openLine, enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown,
            markAskShown: base.markAskShown))
        await model.refresh()
        let changes = Recorder()
        model.changed = { [weak model] in changes.values.append("\(model?.permitsMacScreen(control: true) ?? false)") }
        holdReads = true
        let revoke = Task { await model.set(.control, on: false) }
        for _ in 0..<1000 where changes.values.isEmpty { await Task.yield() }
        #expect(changes.values == ["false"], "Full Control stops while the confirming read still waits")
        #expect(model.permitsMacScreen(control: false) && !model.permitsMacScreen(control: true))
        held.open()
        #expect(await revoke.value == nil)
        #expect(!model.permitsMacScreen(control: true))
    }

    /// A revoke also drops a cached "not joined": a join may have come since that read, so the session
    /// stops at once, before the read that confirms the revoke answers.
    @Test func aRevokeDropsACachedNotJoinedAtOnce() async {
        let fake = Fake()
        fake.record = JoinConsentRecord(screen: true, consentRequired: false)
        let base = fake.services()
        let held = Gate()
        var holdReads = false
        let model = JoinConsentModel(services: JoinConsentServices(
            status: {
                if holdReads { await held.wait() }
                return await base.status()
            },
            openLine: base.openLine, enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown,
            markAskShown: base.markAskShown))
        await model.refresh()
        #expect(model.permitsMacScreen(control: true))
        holdReads = true
        fake.record.consentRequired = true
        let revoke = Task { await model.set(.screen, on: false) }
        for _ in 0..<1000 where !model.writing { await Task.yield() }
        #expect(!model.permitsMacScreen(control: false))
        held.open()
        #expect(await revoke.value == nil)
        #expect(!model.permitsMacScreen(control: false))
    }

    #if DEBUG
    @Test func aCaptureFixtureNeverAuthorizesALiveMacScreenSession() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        fake.record.consentRequired = false
        let base = fake.services()
        let read = Gate()
        var reads = 0
        var held = false
        let model = JoinConsentModel(services: JoinConsentServices(
            status: {
                reads += 1
                if held { await read.wait() }
                return await base.status()
            },
            openLine: base.openLine, enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown,
            markAskShown: base.markAskShown))
        let ticket = SessionTicket(sessionId: "s1", ticket: "a.b.c", signalURL: URL(string: "wss://hub.invalid/v1/sessions/s1/ws")!,
                                   ice: [], peer: .init(id: "v1", name: "Studio", signingKey: "key"), role: .host, scope: .view)
        var fixture = false
        model.fixtureActive = { fixture }
        #expect(await model.macScreenGate(ticket), "an unjoined Mac serves as before")
        // A fixture set while the ticket's read runs.
        held = true
        let pending = Task { await model.macScreenGate(ticket) }
        for _ in 0..<1000 where reads < 2 { await Task.yield() }
        fixture = true
        read.open()
        #expect(!(await pending.value))
        // And one set before.
        #expect(!(await model.macScreenGate(ticket)))
        #expect(!model.macScreenPermits(.view))
        // With the Labs switch off a fixture changes nothing: Mac Screen serves as it did.
        fake.enabled = false
        #expect(await model.macScreenGate(ticket) && model.macScreenPermits(.full))
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

    /// SECURITY: the device owner confirms every grant (Touch ID or the login password) before it is
    /// sent, from the Settings switch and the sheet's Allow alike, whatever input asked for it. A cancel
    /// or a failure sends nothing and leaves the sheet up to try again; a Mac that can't ask grants
    /// nothing and says why; a success sends exactly one set. A revoke and a Deny never ask.
    @Test(arguments: [JoinConsentConfirm.cancelled, .unavailable])
    func aGrantIsSentOnlyAfterTheDeviceOwnerConfirms(refusal: JoinConsentConfirm) async {
        let fake = Fake()
        fake.confirm = refusal
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        let error = refusal == .unavailable ? JoinConsentStrings.confirmUnavailable : JoinConsentStrings.onFailed
        #expect(await model.set(.screen, on: true) == error)
        #expect(fake.writes.isEmpty && fake.confirms == ["screen"], "the switch: asked, nothing sent")
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .control))
        #expect(await model.answer(allow: true) == error)
        #expect(fake.writes.isEmpty && fake.confirms == ["screen", "control"], "the sheet's Allow: asked, nothing sent")
        #expect(model.ask != nil && model.askError == error, "the sheet stays up to try again")
        #expect(!model.permitsMacScreen(control: false))
        fake.confirm = .confirmed
        #expect(await model.answer(allow: true) == nil)
        #expect(fake.writes == ["control true"] && model.ask == nil, "confirmed: exactly one set")
        #expect(await model.set(.screen, on: true) == nil)
        #expect(fake.writes == ["control true", "screen true"] && fake.confirms == ["screen", "control", "control", "screen"])
        // Off and Deny never ask.
        #expect(await model.set(.screen, on: false) == nil)
        #expect(await model.set(.control, on: false) == nil)
        fake.askShown = false
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        #expect(model.ask != nil)
        _ = await model.answer(allow: false)
        #expect(model.ask == nil && fake.confirms.count == 4, "a revoke and a Deny never ask")
        #expect(fake.writes == ["control true", "screen true", "screen false", "control false"])
    }

    /// With no confirm wired, nothing is granted (the default fails closed).
    @Test func withNoConfirmWiredNothingIsGranted() async {
        let fake = Fake()
        let base = fake.services()
        let model = JoinConsentModel(services: JoinConsentServices(status: base.status, openLine: base.openLine, enabled: base.enabled,
                                                                   askShown: base.askShown, markAskShown: base.markAskShown))
        await model.refresh()
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.confirmUnavailable)
        #expect(fake.writes.isEmpty)
    }

    @Test func noAcpmuxIsAFailureNeverAnOn() async {
        let model = JoinConsentModel(services: JoinConsentServices(status: { JoinStatus(credentialPresent: true) }, openLine: { nil },
                                                                   enabled: { true }, confirmOwner: { _ in .confirmed },
                                                                   askShown: { false }, markAskShown: {}))
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

    /// Allow answers only the person's own click on Allow itself, read from the click's events: the
    /// person's mouse-down on Allow, then the person's mouse-up on Allow, each click once. Never Allow's
    /// action: not an Accessibility press or a programmatic click (outside any dispatch, or inside the
    /// dispatch of the person's click on something else, or while Allow is still held), not a click the
    /// strict check refuses (another process's, or DEBUG automation's), not a nested event the check
    /// refuses, and not the same click twice.
    @Test func allowAnswersOnlyThePersonsOwnClickOnAllow() async throws {
        _ = NSApplication.shared
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        let panel = JoinConsentAskPanel(model: model)
        panel.content.rebuild()
        panel.setContentSize(panel.content.fittingSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        let allow = try #require(AddDeviceShotsTests.find(panel.content, id: "cmux.joinConsentAsk.allow") as? NSButton)
        let deny = try #require(AddDeviceShotsTests.find(panel.content, id: "cmux.joinConsentAsk.deny") as? NSButton)
        let center = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        var number = 0
        let event = { (type: NSEvent.EventType, at: NSPoint) throws -> NSEvent in
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: TimeInterval(number),
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 0))
        }
        var genuine: Set<Int> = []
        panel.isPersonEvent = { genuine.contains($0.eventNumber) }
        var current: NSEvent?
        panel.eventInHand = { current }
        let settle = { for _ in 0..<50 { await Task.yield() } }
        /// The person's click: a mouse-down dispatched on `down`'s view, the mouse-up on `up`'s current.
        let click = { (down: NSView, up: NSView, person: Bool, inside: () -> Void) throws in
            let pressed = try event(.leftMouseDown, center(down)), released = try event(.leftMouseUp, center(up))
            if person { genuine.formUnion([pressed.eventNumber, released.eventNumber]) }
            current = pressed
            panel.dispatch(pressed) {
                current = released
                inside()
            }
        }
        _ = allow.accessibilityPerformPress()
        allow.performClick(nil)
        try click(allow, allow, false) { allow.performClick(nil) } // the check refuses it
        try click(deny, deny, true) { _ = allow.accessibilityPerformPress() } // inside the person's click on Deny
        try click(allow, deny, true) { allow.performClick(nil) } // pressed on Allow, released on Deny
        try click(allow, allow, true) { // while Allow is still held
            current = try? event(.leftMouseDragged, center(allow))
            _ = allow.accessibilityPerformPress()
        }
        try click(allow, allow, true) { // inside a nested event the check refuses
            guard let nested = try? event(.leftMouseDown, center(allow)) else { return }
            panel.dispatch(nested) { allow.performClick(nil) }
        }
        await settle()
        #expect(fake.writes.isEmpty && model.ask != nil)
        try click(allow, allow, true) {
            guard let up = current else {
                Issue.record("no mouse-up current")
                return
            }
            #expect(panel.takePersonClick(on: allow, up: up))
            #expect(!panel.takePersonClick(on: allow, up: up), "the same click twice")
        }
        if let up = current { #expect(!panel.takePersonClick(on: allow, up: up), "after the click ended, its mouse-up again") }
        #expect(fake.writes.isEmpty && model.ask != nil)
        try click(allow, allow, true) { allow.performClick(nil) }
        for _ in 0..<1000 where model.ask != nil { await Task.yield() }
        #expect(fake.writes == ["screen true"] && model.ask == nil)
    }

    /// On the displayed sheet AppKit dispatches a click's mouse-up as an event of its own, after the
    /// mouse-down's dispatch or inside it, and Allow's action runs in the mouse-up's dispatch (HQ#5121: a
    /// click on the displayed Allow on a GUI fleet Mac found no mouse-down held). The person's click on Allow
    /// grants there, once, with a drag while held and however often Allow's action is pressed inside it. A
    /// mouse-up the check refuses, one on Deny, another event between the two halves of the click, a click
    /// begun while Allow was disabled and a press after the click grant nothing.
    @Test(arguments: [false, true]) func thePersonsClickOnAllowGrantsWhenItsMouseUpIsDispatchedOnItsOwn(nested: Bool) async throws {
        _ = NSApplication.shared
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        let panel = JoinConsentAskPanel(model: model)
        panel.content.rebuild()
        panel.setContentSize(panel.content.fittingSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        let allow = try #require(AddDeviceShotsTests.find(panel.content, id: "cmux.joinConsentAsk.allow") as? NSButton)
        let deny = try #require(AddDeviceShotsTests.find(panel.content, id: "cmux.joinConsentAsk.deny") as? NSButton)
        let center = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        var number = 0
        let event = { (type: NSEvent.EventType, at: NSPoint) throws -> NSEvent in
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: TimeInterval(number),
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 0))
        }
        var genuine: Set<Int> = []
        panel.isPersonEvent = { genuine.contains($0.eventNumber) }
        var current: NSEvent?
        panel.eventInHand = { current }
        /// The person's mouse-down dispatched on `down`'s view, then `between`, then the mouse-up on `up`'s view
        /// (the person's when `person`) dispatched with `inside` in it: nested in the mouse-down's dispatch or after it.
        let click = { (down: NSView, up: NSView, person: Bool, between: () -> Void, inside: () -> Void) throws in
            let pressed = try event(.leftMouseDown, center(down)), released = try event(.leftMouseUp, center(up))
            genuine.insert(pressed.eventNumber)
            if person { genuine.insert(released.eventNumber) }
            current = pressed
            panel.dispatch(pressed) {
                guard nested else { return }
                between()
                current = released
                panel.dispatch(released, inside)
            }
            guard !nested else { return }
            between()
            current = released
            panel.dispatch(released, inside)
        }
        let other = { (type: NSEvent.EventType) in
            guard let made = try? event(type, center(allow)) else { return }
            genuine.insert(made.eventNumber)
            current = made
            panel.dispatch(made) { _ = allow.accessibilityPerformPress() }
        }
        try click(allow, allow, false, {}) { allow.performClick(nil) } // the check refuses the mouse-up
        try click(allow, deny, true, {}) { allow.performClick(nil) } // pressed on Allow, released on Deny
        _ = allow.accessibilityPerformPress() // after the click, its mouse-up still current
        try click(allow, allow, true, { other(.rightMouseDown) }) { allow.performClick(nil) } // another event between
        allow.isEnabled = false // begun while Allow is disabled (a write in flight), released once it is enabled again
        try click(allow, allow, true, { allow.isEnabled = true }) { allow.performClick(nil) }
        for _ in 0..<50 { await Task.yield() }
        #expect(fake.writes.isEmpty && model.ask != nil)
        try click(allow, allow, true, { other(.leftMouseDragged) }) { // pressed while held, then on the mouse-up
            allow.performClick(nil)
            _ = allow.accessibilityPerformPress()
        }
        for _ in 0..<1000 where model.ask != nil { await Task.yield() }
        #expect(fake.writes == ["screen true"] && model.ask == nil)
    }

    @Test func theStrictPersonCheckTakesOnlyTheHIDSystemsInput() throws {
        let event = { (pid: Int64, state: CGEventSourceStateID) throws -> NSEvent in
            // No event source: making one (CGEventSource) can hang inside SkyLight on a headless Mac. The
            // fields are what the check reads, set as a poster could set them.
            let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                               mouseCursorPosition: .zero, mouseButton: .left))
            cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
            cgEvent.setIntegerValueField(.eventSourceStateID, value: Int64(state.rawValue))
            return try #require(NSEvent(cgEvent: cgEvent))
        }
        let check = PersonInputCheck()
        #expect(check.isPerson(try event(0, .hidSystemState)), "the HID system's")
        #expect(!check.isPerson(try event(0, .privateState)), "a private source, pid 0")
        #expect(!check.isPerson(try event(0, .combinedSessionState)), "a combined-session source, pid 0")
        #expect(!check.isPerson(try event(Int64(getpid()), .hidSystemState)), "this process's own (DEBUG automation)")
        #expect(!check.isPerson(try event(1, .hidSystemState)), "another process's (launchd), from a HID-state source")
        // A real posting process: a child that stays up while it is checked, posting as the cmux-cua helper does.
        let poster = Process()
        poster.executableURL = URL(fileURLWithPath: "/bin/sleep")
        poster.arguments = ["30"]
        try poster.run()
        defer { poster.terminate() }
        #expect(!check.isPerson(try event(Int64(poster.processIdentifier), .hidSystemState)), "a posting process with a HID-state source")
        #expect(!check.isPerson(try event(-1, .hidSystemState)), "no pid")
    }

    /// Turning the Labs switch on drops what was read: nothing is allowed (a running session stops) until
    /// the next read allows it.
    @Test func turningTheLabsSwitchOnStopsUntilAReadAllows() async {
        let fake = Fake()
        fake.enabled = false
        fake.record = JoinConsentRecord(screen: true)
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        let changes = Recorder()
        model.changed = { [weak model] in changes.values.append("\(model?.permitsMacScreen(control: false) ?? false)") }
        fake.enabled = true
        await model.featureChanged()
        #expect(changes.values == ["false", "true"], "stopped at once, then the read allows it")
    }

    /// A read made while a write is in flight never displaces the write's own read after it lands: the
    /// write's read is held, a refresh starts and ends meanwhile, and the write's read still applies.
    @Test func aReadDuringAWriteNeverDiscardsTheWritesConfirmation() async {
        let fake = Fake()
        let base = fake.services()
        let held = Gate()
        var opens = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: base.status,
            openLine: {
                opens += 1
                // 1: the first read; 2: the grant's read before it; 3: its write; 4: its read after.
                if opens == 4 { await held.wait() }
                return await base.openLine()
            },
            enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown, markAskShown: base.markAskShown))
        await model.refresh()
        let grant = Task { await model.set(.screen, on: true) }
        for _ in 0..<1000 where opens < 4 { await Task.yield() }
        #expect(opens == 4 && fake.writes == ["screen true"])
        await model.refresh()
        held.open()
        #expect(await grant.value == nil)
        #expect(model.consent?.screen == true && model.permitsMacScreen(control: false))
    }

    /// When the read after a write fails, the record acpmux answered the write with stands in for it, and
    /// an unread record says so on the page rather than showing a revoke.
    @Test func aFailedReadAfterAWriteKeepsTheWritesRecord() async throws {
        let fake = Fake()
        let base = fake.services()
        let held = Gate()
        var opens = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: base.status,
            openLine: {
                opens += 1
                if opens == 4 { await held.wait() } // the grant's read after its write
                return await base.openLine()
            },
            enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown, markAskShown: base.markAskShown))
        await model.refresh()
        let grant = Task { await model.set(.screen, on: true) }
        for _ in 0..<1000 where opens < 4 { await Task.yield() }
        fake.readFails = true
        held.open()
        #expect(await grant.value == nil)
        #expect(model.consent?.screen == true, "the write's record, acpmux's answer to it")
        #expect(!model.permitsMacScreen(control: false), "the switches show the write's record; Mac Screen waits for a read")
        await model.refresh()
        let data = try #require(model.pageData())
        let page = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(page["error"] as? String == JoinConsentStrings.unread)
        #expect(page["known"] as? Bool == false && page["revoke_all"] as? String == JoinConsentStrings.revokeAll,
                "unknown: the switches are disabled and one action turns both off")
        #expect(!model.permitsMacScreen(control: false), "unread: refused")
        // Off always works, with the record unknown too: both revokes reach acpmux.
        #expect(await model.set(.screen, on: false) == nil)
        #expect(await model.set(.control, on: false) == nil)
        #expect(fake.writes == ["screen true", "screen false", "control false"])
    }

    /// The Labs switch turned off while a grant's line opens: the grant is never sent.
    @Test(arguments: [false, true]) func aGrantIsNeverSentAfterTheLabsSwitchTurnsOff(onAgain: Bool) async {
        let fake = Fake()
        let base = fake.services()
        let held = Gate()
        var opens = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: base.status,
            openLine: {
                opens += 1
                if opens == 3 { await held.wait() }
                return await base.openLine()
            },
            enabled: base.enabled, confirmOwner: base.confirmOwner, askShown: base.askShown, markAskShown: base.markAskShown))
        await model.refresh()
        let grant = Task { await model.set(.screen, on: true) }
        for _ in 0..<1000 where opens < 3 { await Task.yield() }
        fake.enabled = false
        model.featureSwitched()
        if onAgain { // and on again before the line opens: the grant was made before, so it is still never sent
            fake.enabled = true
            model.featureSwitched()
        }
        held.open()
        #expect(await grant.value == JoinConsentStrings.onFailed)
        #expect(fake.writes.isEmpty)
    }

    /// Through the real settings path: the Labs switch turned off and on again in the settings file while a
    /// grant's line opens. Observation may coalesce the two changes and see only "on", so nothing but the
    /// settings load count tells the grant a change came: it is never sent.
    @Test func aGrantIsNeverSentAfterTheLabsSwitchTurnsOffAndOnInTheSettingsFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-join-labs-epoch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        let labs = { (on: Bool) throws in try Data(#"{"labs": {"machineJoin": \#(on)}}"#.utf8).write(to: url) }
        try labs(true)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.snapshot.machineJoin)
        let fake = Fake()
        let base = fake.services()
        let held = Gate()
        var opens = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: base.status,
            openLine: {
                opens += 1
                if opens == 3 { await held.wait() } // the grant's line
                return await base.openLine()
            },
            enabled: { settings.snapshot.machineJoin }, settingsEpoch: { settings.loadCount }, confirmOwner: base.confirmOwner,
            askShown: base.askShown, markAskShown: base.markAskShown))
        await model.refresh()
        let grant = Task { await model.set(.screen, on: true) }
        for _ in 0..<1000 where opens < 3 { await Task.yield() }
        try labs(false)
        await settings.reload()
        try labs(true)
        await settings.reload()
        #expect(settings.snapshot.machineJoin, "on again before the grant's line opens")
        held.open()
        #expect(await grant.value == JoinConsentStrings.onFailed)
        #expect(fake.writes.isEmpty)
        // With no settings change in between, the person's grant goes through.
        #expect(await model.set(.screen, on: true) == nil)
        #expect(fake.writes == ["screen true"])
    }

    /// The Labs switch turns off (and on again) after the model's last check, while the line holds the grant
    /// to write: the line writes it only through its ticket, which the switch made stale, so it is never
    /// sent. A revoke is written whatever moved.
    @Test(arguments: [false, true]) func aGrantIsNeverWrittenWhenTheLabsSwitchMovesAfterItsLastCheck(onAgain: Bool) async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        fake.beforeWrite = { [unowned fake, unowned model] in
            fake.enabled = false
            model.featureSwitched()
            if onAgain {
                fake.enabled = true
                model.featureSwitched()
            }
        }
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        #expect(fake.writes.isEmpty, "the stale grant's bytes never went out")
        fake.beforeWrite = nil
        fake.enabled = true
        #expect(await model.set(.screen, on: true) == nil)
        #expect(fake.writes == ["screen true"])
        fake.beforeWrite = { [unowned fake, unowned model] in
            fake.enabled = false
            model.featureSwitched()
        }
        #expect(await model.set(.screen, on: false) == nil)
        #expect(fake.writes == ["screen true", "screen false"], "a revoke is written whatever moved")
    }

    /// Through the real settings path: a settings load comes after the model's last check, while the line
    /// holds the grant to write. The load invalidates the gate as it happens (the app's
    /// ``JoinConsentModel/invalidateGrants(_:onEveryLoadOf:)``), so the grant is never sent, with the Labs
    /// switch off and on again or with no change at all.
    @Test(arguments: [true, false]) func aGrantIsNeverWrittenWhenTheSettingsLoadAfterItsLastCheck(labsMoves: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-join-labs-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        let labs = { (on: Bool) throws in try Data(#"{"labs": {"machineJoin": \#(on)}}"#.utf8).write(to: url) }
        try labs(true)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let fake = Fake()
        let base = fake.services()
        let model = JoinConsentModel(services: JoinConsentServices(
            status: base.status, openLine: base.openLine,
            enabled: { settings.snapshot.machineJoin }, settingsEpoch: { settings.loadCount }, confirmOwner: base.confirmOwner,
            askShown: base.askShown, markAskShown: base.markAskShown))
        JoinConsentModel.invalidateGrants(model.grantGate, onEveryLoadOf: settings)
        await model.refresh()
        fake.beforeWrite = {
            if labsMoves {
                try? labs(false)
                await settings.reload()
                try? labs(true)
            }
            await settings.reload()
        }
        #expect(await model.set(.screen, on: true) == JoinConsentStrings.onFailed)
        #expect(settings.snapshot.machineJoin)
        #expect(fake.writes.isEmpty, "the stale grant's bytes never went out")
        // With no load in between, the person's grant goes through.
        fake.beforeWrite = nil
        #expect(await model.set(.screen, on: true) == nil)
        #expect(fake.writes == ["screen true"])
    }

    /// A join status that fails to read leaves an open sheet up; only the Labs switch off, a join gone or
    /// revoked closes it.
    @Test func anUnreadJoinStatusNeverClosesTheSheet() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: .screen))
        fake.status = nil
        await model.refresh()
        #expect(model.ask != nil)
        fake.takes = false
        #expect(await model.answer(allow: true) == JoinConsentStrings.onFailed)
        #expect(model.ask != nil && model.askError == JoinConsentStrings.onFailed)
        fake.status = JoinStatus(credentialPresent: true, machineId: "m_1", revoked: true)
        await model.refresh()
        #expect(model.ask == nil)
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
        page.personBacksGesture = { _ in true } // the gesture's origin is the next test's
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

    /// A synthesized click on the Settings page's switch: the page saw a real event, but one posted from a
    /// HID-state source by another process (how the cmux-cua helper clicks). Turning a consent on with it
    /// changes nothing; turning one off with the same click works (off takes any input). The person's own
    /// click from the HID system turns it on; one posted right after the person's backs nothing.
    @Test func aPostedClickOnTheSettingsSwitchGrantsNothingButRevokes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-join-posted-\(UUID().uuidString)")
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
        let ledger = PersonInputLedger()
        page.personBacksGesture = { ledger.backs($0) }
        let poster = Process()
        poster.executableURL = URL(fileURLWithPath: "/bin/sleep")
        poster.arguments = ["30"]
        try poster.run()
        defer { poster.terminate() }
        var second: UInt64 = 100
        let click = { (pid: Int64) throws -> NSEvent in
            second += 1
            // No event source (making one can hang inside SkyLight on a headless Mac); the fields are set below.
            let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                               mouseCursorPosition: .zero, mouseButton: .left))
            cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
            cgEvent.setIntegerValueField(.eventSourceStateID, value: Int64(CGEventSourceStateID.hidSystemState.rawValue))
            cgEvent.timestamp = second * 1_000_000_000
            return try #require(NSEvent(cgEvent: cgEvent))
        }
        /// The page's call for `event` (the gesture the page recorded is the event's own time).
        let call = { (event: NSEvent, on: Bool) async throws in
            ledger.record(event)
            _ = try await page.call("cmux.settings.devices.join_consent", params: ["surface": "screen", "on": .bool(on)],
                                    context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: event.timestamp))
        }
        let posted = try click(Int64(poster.processIdentifier))
        do {
            try await call(posted, true)
            Issue.record("a posted click turned it on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(sets.values.isEmpty, "consent unchanged")
        try await call(posted, false)
        #expect(sets.values == ["screen false"], "the same posted click turns it off")
        let person = try click(0)
        try await call(person, true)
        #expect(sets.values == ["screen false", "screen true"], "the person's own click turns it on")
        // The person clicks, then a posted click lands before the page's call for the person's.
        let mine = try click(0)
        ledger.record(mine)
        ledger.record(try click(Int64(poster.processIdentifier)))
        do {
            _ = try await page.call("cmux.settings.devices.join_consent", params: ["surface": "control", "on": true],
                                    context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: mine.timestamp))
            Issue.record("a posted click right after the person's backed a grant")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(sets.values == ["screen false", "screen true"])
    }

    /// Round 15: the folder made at the first join, with its consent file, in the window right after the
    /// watch is armed and before its first ask or its loop runs (the `armed` handshake). The watch moved to
    /// the new folder and its file: a later in-place write of that file, which only the file's own watch
    /// sees, still asks. A watch armed after that window would have armed no file watch and miss it.
    @Test func theFolderMadeRightAfterTheWatchArmsIsFollowed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-machine-consent-arm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "machine-consent")
        let file = folder.appending(path: "consent.json")
        var made = false
        let stream = await MachineConsentChanges(folder: folder).events {
            made = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
                && (try? Data("{}".utf8).write(to: file)) != nil
        }
        #expect(made, "the folder and its file were made in the window")
        let changes = Recorder()
        let watching = Task {
            for await _ in stream { changes.values.append("change") }
        }
        defer { watching.cancel() }
        // Lets the first ask and the folder's own element land, then writes the file in place.
        let first = ContinuousClock.now + .seconds(10)
        while changes.values.isEmpty, ContinuousClock.now < first { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!changes.values.isEmpty, "one ask once the watch is armed")
        try await Task.sleep(for: .milliseconds(500))
        let seen = changes.values.count
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while changes.values.count == seen, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes.values.count > seen, "the file made in the window is watched")
    }

    /// The machine consent folder comes from the user's password entry, never HOME or ACPMUX_HOME. Its
    /// watch asks once as soon as it is armed (so nothing made while it armed is missed), then once per
    /// change: the folder made at the first join, a file made, rewritten in place, replaced by a rename,
    /// and the folder removed and made again. Each step waits for its own element, counted from a quiet
    /// point, so an earlier duplicate never stands in for it.
    @Test func theMachineConsentWatchFollowsTheUsersFolderAndItsFiles() async throws {
        let entry = try #require(getpwuid(geteuid()))
        let home = String(cString: try #require(entry.pointee.pw_dir))
        #expect(MachineConsentChanges.folder?.path == home + "/.acpmux/machine-consent")
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-machine-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "machine-consent")
        let changes = Recorder()
        let watching = Task {
            for await _ in await MachineConsentChanges(folder: folder).events() { changes.values.append("change") }
        }
        defer { watching.cancel() }
        /// Lets earlier events land, then does `change` and waits for an element after it.
        func step(_ what: String, _ change: () throws -> Void) async throws {
            try await Task.sleep(for: .milliseconds(300))
            let seen = changes.values.count
            try change()
            let deadline = ContinuousClock.now + .seconds(10)
            while changes.values.count == seen, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(changes.values.count > seen, "\(what)")
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while changes.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!changes.values.isEmpty, "one ask as soon as the watch is armed")
        let file = folder.appending(path: "consent.json")
        try await step("the folder made at the first join") { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try await step("a file made") { try Data("{}".utf8).write(to: file) }
        try await step("a file rewritten in place") {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        }
        try await step("a file replaced by a rename") {
            let next = folder.appending(path: ".consent.json.tmp")
            try Data("{\"screen\":1}".utf8).write(to: next)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: next)
        }
        try await step("a file rewritten in place after its replacement") {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        }
        try await step("the folder removed") { try FileManager.default.removeItem(at: folder) }
        try await step("the folder made again") { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try await step("a file made in the new folder") { try Data("{}".utf8).write(to: file) }
    }
}
