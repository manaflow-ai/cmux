import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse
@testable import CmuxNextMacScreen
import CmuxNextDesign
import CmuxNextSettings

/// Computer Use app approvals on the Mac (docs/computer-use-approvals.md): the request checks,
/// the host link lines, the per-client saved list, the broker's single-use decisions from the
/// card and the phone, and the card's dialog.
@MainActor
struct ComputerUseApprovalTests {
    static let client = "com.cmuxterm.app.debug.cu1"
    static let nowMs: Int64 = 1_793_400_000_000

    /// A request object as the worker sends it (digest over the canonical JSON).
    static func requestObject(client: String = client, bundleID: String = "com.apple.Safari", nonce: String = String(repeating: "a", count: 32),
                              created: Int64 = nowMs, waitUntil: Int64 = nowMs + 120_000,
                              answerableUntil: Int64 = nowMs + 600_000) -> [String: Any] {
        var object: [String: Any] = [
            "v": 1, "nonce": nonce, "client": client, "machine": "mac-1", "session": "s-1",
            "agent": "Claude", "workspace": "api-server",
            "target": ["bundle_id": bundleID, "executable": NSNull(), "name": "Safari"] as [String: Any],
            "tool": "click", "risk": "R1",
            "created_ms": created, "wait_until_ms": waitUntil, "answerable_until_ms": answerableUntil,
        ]
        object["digest"] = ComputerUseApprovalRequest.digest(of: ComputerUseCanonicalJSON(foundation: object)!)
        return object
    }

    static func request(_ object: [String: Any] = requestObject()) throws -> ComputerUseApprovalRequest {
        try #require(ComputerUseApprovalRequest(object))
    }

    static func json(_ line: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    static func temporaryFile(client: String = client) -> ComputerUseApprovalFile {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cu-approvals-\(UUID().uuidString)")
        return .standard(client: client, support: root)
    }

    // MARK: Request

    @Test func canonicalJSONMatchesSerdeBytes() {
        let value = ComputerUseCanonicalJSON(foundation: ["b": [1, true, NSNull()] as [Any], "a": "x\"\\\n\u{1}é/", "A": -2] as [String: Any])
        #expect(value?.canonicalText == #"{"A":-2,"a":"x\"\\\n\u0001é/","b":[1,true,null]}"#)
        #expect(ComputerUseCanonicalJSON(foundation: ["x": 1.5]) == nil)
    }

    @Test func aRequestCountsOnlyWithItsOwnDigest() throws {
        let request = try Self.request()
        #expect(request.target == ComputerUseApprovalApp(bundleID: "com.apple.Safari", executable: nil, name: "Safari"))
        #expect(request.id == String(request.digest.prefix(16)))
        var tampered = Self.requestObject()
        tampered["agent"] = "Someone else"
        #expect(ComputerUseApprovalRequest(tampered) == nil)
        var badDigest = Self.requestObject()
        badDigest["digest"] = String(repeating: "0", count: 64)
        #expect(ComputerUseApprovalRequest(badDigest) == nil)
        var noTarget = Self.requestObject()
        noTarget["target"] = ["name": "Safari"]
        noTarget["digest"] = nil
        noTarget["digest"] = ComputerUseApprovalRequest.digest(of: ComputerUseCanonicalJSON(foundation: noTarget)!)
        #expect(ComputerUseApprovalRequest(noTarget) == nil)
    }

    // MARK: Host link

    @Test func approvalLinesParseAndAnswer() throws {
        let object = Self.requestObject()
        #expect(ComputerUseApprovalWire.parse(["type": "app_approval", "id": 7, "request": object]) == .question(id: 7, request: try Self.request(object)))
        #expect(ComputerUseApprovalWire.parse(["type": "app_approval", "id": 8, "request": ["v": 1]]) == .malformed(id: 8))
        #expect(ComputerUseApprovalWire.parse(["type": "app_approval_cancel", "id": 7]) == .cancel(id: 7))
        #expect(ComputerUseApprovalWire.parse(["type": "machine_consent", "id": 7]) == nil)

        let answer = try Self.json(ComputerUseApprovalWire.answer(id: 7, decision: .session, digest: "d", via: .phone))
        #expect(answer["type"] as? String == "app_approval")
        #expect(answer["id"] as? Int == 7)
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["decision"] as? String == "session")
        #expect(answer["digest"] as? String == "d")
        #expect(answer["via"] as? String == "phone")
        #expect(try Self.json(ComputerUseApprovalWire.unanswered(id: 9)) as NSDictionary == ["type": "app_approval", "id": 9, "ok": false])
        let apps = try Self.json(ComputerUseApprovalWire.approvedApps([.init(bundleID: "com.apple.Notes", executable: nil, name: "Notes"),
                                                                       .init(bundleID: nil, executable: "/usr/bin/xterm", name: "xterm")]))
        #expect(apps["type"] as? String == "approved_apps")
        #expect((apps["apps"] as? [[String: String]]) == [["bundle_id": "com.apple.Notes", "name": "Notes"], ["executable": "/usr/bin/xterm", "name": "xterm"]])
        #expect(try Self.json(ComputerUseApprovalWire.revoke(nil)) as NSDictionary == ["type": "revoke", "scope": "all"])
        let one = try Self.json(ComputerUseApprovalWire.revoke(.init(bundleID: "com.apple.Notes", executable: nil, name: "Notes")))
        #expect(one["scope"] as? String == "app")
        #expect((one["app"] as? [String: String])?["bundle_id"] == "com.apple.Notes")
    }

    @Test(.timeLimit(.minutes(1))) func withoutABrokerEveryQuestionIsRefused() async throws {
        let (lines, sink) = AsyncStream<Data>.makeStream()
        let handled = ComputerUseHelperV2Consent.handle(["type": "app_approval", "id": 4, "request": Self.requestObject()],
                                                        send: { sink.yield($0) }, consent: { nil }, refused: { _ in })
        #expect(handled)
        let line = try #require(await Inbox(lines).next())
        #expect(try Self.json(line) as NSDictionary == ["type": "app_approval", "id": 4, "ok": false])
    }

    // MARK: Store

    /// File I/O off the main actor, as the store does it.
    static func read(_ file: ComputerUseApprovalFile) async -> [ComputerUseSavedApproval] {
        await Task.detached { file.read() }.value
    }

    static func write(_ file: ComputerUseApprovalFile, _ apps: [ComputerUseSavedApproval]) async {
        await Task.detached { _ = file.write(apps) }.value
    }

    @Test(.timeLimit(.minutes(1))) func savedApprovalsArePerClientAndPrivate() async throws {
        let file = Self.temporaryFile()
        let store = ComputerUseApprovalStore(file: file)
        await store.load()
        store.add(.init(bundleID: "com.apple.Safari", executable: nil, name: "Safari"), via: .mac, nowMs: 5)
        store.add(.init(bundleID: "com.apple.Safari", executable: nil, name: "Safari 2"), via: .mac, nowMs: 6)
        store.add(.init(bundleID: nil, executable: "/usr/bin/xterm", name: "xterm"), via: .phone, nowMs: 7)
        await store.flush()
        #expect(store.apps.count == 2)
        var info = stat()
        #expect(stat(file.url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(await Self.read(file).map(\.app.name) == ["Safari", "xterm"])

        // Another client (another build) at the same path reads nothing.
        #expect(await Self.read(ComputerUseApprovalFile(url: file.url, client: "com.cmuxterm.app.nightly")).isEmpty)
        // A fresh store of the same client sees the list; one of another client does not.
        let again = ComputerUseApprovalStore(file: file)
        await again.load()
        #expect(again.apps.map(\.app.name) == ["Safari", "xterm"])
        let other = ComputerUseApprovalStore(file: Self.temporaryFile(client: "com.cmuxterm.app"))
        await other.load()
        #expect(other.apps.isEmpty)

        #expect(again.revoke(.init(bundleID: "com.apple.Safari", executable: nil, name: "")) == 1)
        await again.flush()
        #expect(await Self.read(file).map(\.app.name) == ["xterm"])
        #expect(again.revoke(nil) == 1)
        await again.flush()
        #expect(await Self.read(file).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aRevokeBeforeTheFirstReadIsKept() async throws {
        let file = Self.temporaryFile()
        await Self.write(file, [ComputerUseSavedApproval(app: .init(bundleID: "com.apple.Notes", executable: nil, name: "Notes"), addedMs: 1, via: .mac)])
        let store = ComputerUseApprovalStore(file: file)
        store.revoke(nil)
        await store.load()
        await store.flush()
        #expect(store.apps.isEmpty)
        #expect(await Self.read(file).isEmpty)
    }

    @Test func aFileOthersCanReadCountsAsEmpty() async throws {
        let file = Self.temporaryFile()
        await Self.write(file, [ComputerUseSavedApproval(app: .init(bundleID: "com.apple.Notes", executable: nil, name: "Notes"), addedMs: 1, via: .mac)])
        #expect(await Self.read(file).count == 1)
        chmod(file.url.path, 0o644)
        #expect(await Self.read(file).isEmpty)
    }

    // MARK: Broker

    final class FakePresenter: ComputerUseApprovalPresenting {
        var shown: [String] = []
        var withdrawn: [String] = []
        func show(_ pending: ComputerUseApprovalPending, broker: ComputerUseApprovalBroker) { shown.append(pending.id) }
        func withdraw(_ id: String) { withdrawn.append(id) }
    }

    final class FakePhone: ComputerUseApprovalPhoneRelay {
        var asked: [(String, Bool)] = []
        var finished: [String] = []
        func ask(_ request: ComputerUseApprovalRequest, allowsAlways: Bool) { asked.append((request.digest, allowsAlways)) }
        func done(digest: String) { finished.append(digest) }
    }

    /// The lines the broker sends on one link, read in order on the main actor.
    final class Inbox {
        private var queued: [Data] = []
        private var waiter: CheckedContinuation<Data?, Never>?
        private var ended = false
        private var reader: Task<Void, Never>?

        init(_ stream: AsyncStream<Data>) {
            reader = Task { [weak self] in
                for await line in stream { self?.take(line) }
                self?.finish()
            }
        }

        private func take(_ line: Data) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: line)
            } else {
                queued.append(line)
            }
        }

        private func finish() {
            ended = true
            waiter?.resume(returning: nil)
            waiter = nil
        }

        func next() async -> Data? {
            if !queued.isEmpty { return queued.removeFirst() }
            if ended { return nil }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    struct Rig {
        let broker: ComputerUseApprovalBroker
        let presenter: FakePresenter
        let phone: FakePhone
        let link: Int
        let inbox: Inbox

        func next() async throws -> [String: Any] {
            try ComputerUseApprovalTests.json(try #require(await inbox.next()))
        }
    }

    func makeRig(nowMs: Int64 = nowMs) async -> Rig {
        let store = ComputerUseApprovalStore(file: Self.temporaryFile())
        await store.load()
        let broker = ComputerUseApprovalBroker(store: store, nowMs: { nowMs })
        let presenter = FakePresenter()
        let phone = FakePhone()
        broker.presenter = presenter
        broker.phone = phone
        let (lines, sink) = AsyncStream<Data>.makeStream()
        let link = broker.attach(sink)
        return Rig(broker: broker, presenter: presenter, phone: phone, link: link, inbox: Inbox(lines))
    }

    @Test(.timeLimit(.minutes(1))) func aCardPressAnswersOnceAndOnlyOnce() async throws {
        let rig = await makeRig()
        #expect(try await rig.next()["type"] as? String == "approved_apps")
        let request = try Self.request()
        rig.broker.receive(.question(id: 7, request: request), link: rig.link)
        #expect(rig.presenter.shown == [request.id])
        #expect(rig.phone.asked.map(\.0) == [request.digest])
        #expect(rig.phone.asked.first?.1 == false)
        // The same question again (a parallel call) joins it.
        rig.broker.receive(.question(id: 8, request: request), link: rig.link)
        #expect(rig.broker.pending.count == 1)

        #expect(rig.broker.decide(request.id, decision: .session))
        #expect(!rig.broker.decide(request.id, decision: .always))
        let answer = try await rig.next()
        #expect(answer["id"] as? Int == 7)
        #expect(answer["decision"] as? String == "session")
        #expect(answer["digest"] as? String == request.digest)
        #expect(answer["via"] as? String == "mac")
        #expect(rig.presenter.withdrawn == [request.id])
        #expect(rig.phone.finished == [request.digest])
        #expect(rig.broker.store.apps.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func alwaysOnTheCardSavesTheAppAndTellsTheWorker() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let request = try Self.request()
        rig.broker.receive(.question(id: 1, request: request), link: rig.link)
        #expect(rig.broker.decide(request.id, decision: .always))
        let saved = try await rig.next()
        #expect(saved["type"] as? String == "approved_apps")
        #expect((saved["apps"] as? [[String: String]]) == [["bundle_id": "com.apple.Safari", "name": "Safari"]])
        let answer = try await rig.next()
        #expect(answer["decision"] as? String == "always")
        #expect(rig.broker.store.apps.map(\.via) == [.mac])

        #expect(rig.broker.revoke(request.target) == 1)
        #expect(try await rig.next()["apps"] as? [Any] != nil)
        let revoke = try await rig.next()
        #expect(revoke["type"] as? String == "revoke")
        #expect(revoke["scope"] as? String == "app")
    }

    @Test(.timeLimit(.minutes(1))) func questionsOutsideThisClientOrTimeAreRefused() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        rig.broker.receive(.question(id: 2, request: try Self.request(Self.requestObject(client: "com.cmuxterm.app"))), link: rig.link)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 2, "ok": false])
        rig.broker.receive(.question(id: 3, request: try Self.request(Self.requestObject(created: Self.nowMs - 700_000, waitUntil: Self.nowMs - 600_000,
                                                                                                answerableUntil: Self.nowMs - 1))), link: rig.link)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 3, "ok": false])
        rig.broker.receive(.malformed(id: 4), link: rig.link)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 4, "ok": false])
        #expect(rig.broker.pending.isEmpty)
        #expect(rig.presenter.shown.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cmuxItselfAndOverlongWindowsAreNeverAsked() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        rig.broker.receive(.question(id: 1, request: try Self.request(Self.requestObject(bundleID: Self.client))), link: rig.link)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 1, "ok": false])
        rig.broker.receive(.question(id: 2, request: try Self.request(Self.requestObject(bundleID: "com.cmuxterm.remote"))), link: rig.link)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 2, "ok": false])
        rig.broker.receive(.question(id: 3, request: try Self.request(Self.requestObject(answerableUntil: Self.nowMs + 86_400_000))), link: rig.link)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 3, "ok": false])
        #expect(rig.broker.pending.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func expiryAndCancelWithdrawWithoutADecision() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let first = try Self.request()
        let second = try Self.request(Self.requestObject(bundleID: "com.apple.Notes", nonce: String(repeating: "b", count: 32)))
        rig.broker.receive(.question(id: 1, request: first), link: rig.link)
        rig.broker.receive(.question(id: 2, request: second), link: rig.link)
        rig.broker.expire(first.id)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 1, "ok": false])
        rig.broker.receive(.cancel(id: 2), link: rig.link)
        #expect(rig.broker.pending.isEmpty)
        #expect(Set(rig.presenter.withdrawn) == [first.id, second.id])
        #expect(!rig.broker.decide(first.id, decision: .once))
        // A lost link ends its questions.
        let third = try Self.request(Self.requestObject(nonce: String(repeating: "c", count: 32)))
        rig.broker.receive(.question(id: 5, request: third), link: rig.link)
        rig.broker.detach(rig.link)
        #expect(rig.broker.pending.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func promptShowsTheCardAgainAndNeverDecides() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let request = try Self.request()
        rig.broker.receive(.question(id: 1, request: request), link: rig.link)
        #expect(rig.broker.prompt(request.id))
        #expect(rig.broker.prompt(request.digest))
        #expect(!rig.broker.prompt("nope"))
        #expect(rig.presenter.shown == [request.id, request.id, request.id])
        #expect(rig.broker.pending.count == 1)
    }

    // MARK: Phone

    static func signed(_ key: P256.Signing.PrivateKey, phone: String = "phone-1", digest: String, decision: ComputerUseApprovalDecision,
                       expiresAt: Int64 = nowMs / 1000 + 120) throws -> ComputerUseApprovalPhoneAnswer {
        let message = ComputerUseApprovalPhoneAnswer.message(phone: phone, digest: digest, decision: decision, expiresAt: expiresAt)
        let signature = try key.signature(for: message).rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return ComputerUseApprovalPhoneAnswer(phoneDeviceID: phone, digest: digest, decision: decision, expiresAt: expiresAt, signature: signature)
    }

    static func hex(_ key: P256.Signing.PrivateKey) -> String {
        key.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined()
    }

    @Test(.timeLimit(.minutes(1))) func aPhoneAllowCountsOnlyWithThatPhonesFaceIDSignature() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let key = P256.Signing.PrivateKey()
        let stranger = P256.Signing.PrivateKey()
        rig.broker.phoneApprovalKey = { $0 == "phone-1" ? Self.hex(key) : nil }
        let request = try Self.request()
        rig.broker.receive(.question(id: 1, request: request), link: rig.link)

        var unsigned = try Self.signed(key, digest: request.digest, decision: .once)
        unsigned.signature = nil
        #expect(!rig.broker.phoneAnswered(unsigned))
        #expect(!rig.broker.phoneAnswered(try Self.signed(stranger, digest: request.digest, decision: .once)))
        #expect(!rig.broker.phoneAnswered(try Self.signed(key, phone: "phone-2", digest: request.digest, decision: .once)))
        #expect(!rig.broker.phoneAnswered(try Self.signed(key, digest: request.digest, decision: .once, expiresAt: Self.nowMs / 1000 - 1)))
        #expect(!rig.broker.phoneAnswered(try Self.signed(key, digest: request.digest, decision: .once, expiresAt: Self.nowMs / 1000 + 301)))
        var forged = try Self.signed(key, digest: request.digest, decision: .once)
        forged.decision = .session
        #expect(!rig.broker.phoneAnswered(forged))
        #expect(rig.broker.pending.count == 1)

        #expect(rig.broker.phoneAnswered(try Self.signed(key, digest: request.digest, decision: .session)))
        #expect(!rig.broker.phoneAnswered(try Self.signed(key, digest: request.digest, decision: .once)))
        let answer = try await rig.next()
        #expect(answer["decision"] as? String == "session")
        #expect(answer["via"] as? String == "phone")
    }

    @Test(.timeLimit(.minutes(1))) func aPhoneDenyNeedsNoSignature() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let request = try Self.request()
        rig.broker.receive(.question(id: 1, request: request), link: rig.link)
        #expect(rig.broker.phoneAnswered(ComputerUseApprovalPhoneAnswer(phoneDeviceID: "phone-9", digest: request.digest, decision: .deny,
                                                                        expiresAt: Self.nowMs / 1000 + 60, signature: nil)))
        #expect(try await rig.next()["decision"] as? String == "deny")
    }

    @Test(.timeLimit(.minutes(1))) func aPhoneAlwaysNeedsTheSettingAndFaceID() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let key = P256.Signing.PrivateKey()
        rig.broker.phoneApprovalKey = { _ in Self.hex(key) }
        let request = try Self.request()
        rig.broker.receive(.question(id: 1, request: request), link: rig.link)
        #expect(!rig.broker.phoneAnswered(try Self.signed(key, digest: request.digest, decision: .always)))
        #expect(rig.broker.store.apps.isEmpty)

        var allowed = false
        rig.broker.phoneAlwaysAllow = { allowed }
        allowed = true
        rig.broker.reaskPhone()
        #expect(rig.phone.asked.last?.1 == true)
        var unsigned = try Self.signed(key, digest: request.digest, decision: .always)
        unsigned.signature = nil
        #expect(!rig.broker.phoneAnswered(unsigned))
        #expect(rig.broker.phoneAnswered(try Self.signed(key, digest: request.digest, decision: .always)))
        #expect(rig.broker.store.apps.map(\.via) == [.phone])
        #expect(try await rig.next()["type"] as? String == "approved_apps")
        #expect(try await rig.next()["decision"] as? String == "always")
    }

    // MARK: Card

    @Test func theCardNamesWhoAsksAndEscapeDenies() throws {
        let request = try Self.request()
        let spec = ComputerUseApprovalCards.spec(for: request, icon: Data([1, 2]), timeZone: TimeZone(identifier: "UTC")!)
        #expect(spec.title.contains("Claude"))
        #expect(spec.title.contains("Safari"))
        #expect(spec.lines.joined().contains("api-server"))
        #expect(spec.lines.joined().contains(Self.client))
        #expect(spec.icon == Data([1, 2]))
        #expect(spec.buttons.map(\.id) == ["deny", "always", "session", "once"])
        #expect(spec.cancelButton?.id == "deny")
        #expect(spec.lines.contains("com.apple.Safari"))
        // No key grants: Return presses nothing, no allow has a Command key.
        #expect(spec.defaultButton == nil)
        #expect(spec.buttons.compactMap(\.key).isEmpty)
        #expect(spec.buttons.first { $0.id == "always" }?.title.contains("Safari") == true)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("deny"))
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aPressOnTheCardDecidesThroughTheBroker() async throws {
        let rig = await makeRig()
        _ = try await rig.next()
        let cards = ComputerUseApprovalCards(panels: false)
        rig.broker.presenter = cards
        let first = try Self.request()
        let second = try Self.request(Self.requestObject(bundleID: "com.apple.Notes", nonce: String(repeating: "b", count: 32)))
        rig.broker.receive(.question(id: 1, request: first), link: rig.link)
        rig.broker.receive(.question(id: 2, request: second), link: rig.link)
        let dialog = try #require(cards.dialogID(first.id))
        #expect(cards.dialogID(second.id) != nil)
        #expect(cards.center.press(dialog, button: "deny"))
        let answer = try await rig.next()
        #expect(answer["id"] as? Int == 1)
        #expect(answer["decision"] as? String == "deny")
        #expect(cards.dialogID(first.id) == nil)
        // Withdrawn from elsewhere (a phone answered): the card goes and decides nothing more.
        rig.broker.expire(second.id)
        #expect(cards.dialogID(second.id) == nil)
        #expect(try await rig.next() as NSDictionary == ["type": "app_approval", "id": 2, "ok": false])
    }

    @Test func revokeDialogListsEachSavedApp() {
        let empty = ComputerUseApprovalActions.revokeSpec([])
        #expect(empty.buttons.map(\.id) == ["ok"])
        let spec = ComputerUseApprovalActions.revokeSpec([.init(bundleID: "com.apple.Notes", executable: nil, name: "Notes"),
                                                          .init(bundleID: nil, executable: "/usr/bin/xterm", name: "xterm")])
        #expect(spec.fields.compactMap(\.id) == ["app.0", "app.1"])
        #expect(spec.buttons.map(\.id) == ["cancel", "all", "chosen"])
        #expect(spec.cancelButton?.id == "cancel")
    }

    @Test func onlyAHigherModeNeedsThePerson() {
        #expect(ComputerUseMode.unrestricted.raises(over: .standard))
        #expect(ComputerUseMode.standard.raises(over: .ask))
        #expect(ComputerUseMode.bounded.raises(over: .ask))
        #expect(!ComputerUseMode.ask.raises(over: .bounded))
        #expect(!ComputerUseMode.ask.raises(over: .ask))
    }
}
