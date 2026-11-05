import AppKit
import Foundation
@testable import CmuxNextServer
import Testing

/// Add Device's "Any machine" way (the default, no Labs switch): hidden when the app offers no join,
/// first and opened on by default with ssh behind Advanced, a line only on Make Line, joined when a listed machine carries the line's `joinTokenId`,
/// expired at `expiresAt`, the list read on a trigger (the line shown, the focus, a mesh change) and
/// never on a timer, and the countdown and mesh watch stopped on close, on the flip and at expiry.
@MainActor @Suite(.serialized) struct MachineJoinLineFlowTests {
    // The service's closures are @Sendable and run off the main actor: the fake is not isolated to it.
    // The suite is serialized and each test drives one model, so no two calls race.
    nonisolated final class Fake: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var rows: [JoinedMachine] = []
        var lists = 0
        var mints: [String?] = []
        var doctors: [String] = []
        var mintResult: Result<JoinLine, JoinLineFailure>?
        var mesh: AsyncStream<Void>.Continuation?
        // Ten minutes after the clock's start.
        var line = JoinLine(line: " curl -fsSL https://cmux.example/v1/machines/join.sh | CMUX_JOIN=cmj_TESTTOKEN sh",
                            joinTokenId: "jt_1", expiresAt: Date(timeIntervalSince1970: 1_000_600), name: nil)

        func service() -> MachineJoinService {
            MachineJoinService(
                mint: { [self] name in mints.append(name); return mintResult ?? .success(line) },
                list: { [self] in lists += 1; return rows },
                doctor: { [self] id in doctors.append(id); return [HostStepResult(step: HostStep(rawValue: "heartbeat"), state: .ok)] },
                meshChanges: { [self] in AsyncStream { mesh = $0 } })
        }

        @MainActor func model() -> MachineJoinLineModel {
            // The countdown's sleep waits until it is cancelled: these tests move time by hand (tick()).
            MachineJoinLineModel(service: service(), clock: { [self] in now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        }

        @MainActor func deviceModel(_ services: AddDeviceServices) -> AddDeviceModel {
            AddDeviceModel(services: services, joinClock: { [self] in now }, joinSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        }

        static func joined(_ token: String?, name: String = "lane-vm-3") -> JoinedMachine {
            JoinedMachine(id: "m_\(name)", name: name, state: .online, joinTokenId: token, mintedBy: "you@example.com")
        }
    }

    @Test func theWayIsHiddenWhenTheAppOffersNoJoin() async {
        let devices = AddDeviceFlowTests.Fake()
        let model = AddDeviceModel(services: devices.services())
        await model.begin(way: .joinLine)
        #expect(model.joinLine == nil)
        #expect(!model.ways.contains(.joinLine), "no join way without a join service")
        #expect(model.advancedWays.isEmpty, "the ssh way stays in the switch, with no Advanced")
        #expect(model.way == .network, "asking for the hidden way opens the card as it opens on its own")
        model.choose(.joinLine)
        #expect(model.way == .network)
    }

    @Test func theWayIsTheDefaultAndMintsOnlyOnMakeLine() async {
        let fake = Fake()
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(Self.services(devices, fake))
        await model.begin()
        #expect(model.ways == [.joinLine, .code, .newDevice])
        #expect(model.advancedWays == [.network], "ssh moves behind Advanced")
        #expect(model.way == .joinLine, "the card opens on the no-ssh way, though the network lists a computer")
        #expect(!model.showsAdvanced)
        model.choose(.joinLine)
        #expect(model.joinLine?.phase == .idle)
        #expect(fake.mints.isEmpty, "choosing the way mints nothing")
        #expect(model.buttons.map(\.action) == [.cancel, .makeJoinLine])
        model.joinLine?.name = "  lane-vm-3 "
        await model.joinLine?.mint()
        #expect(fake.mints == ["lane-vm-3"])
        #expect(model.joinLine?.line == fake.line)
        #expect(model.buttons.map(\.action) == [.cancel, .copyJoinLine])
    }

    @Test func copyLinePutsTheLineOnTheConcealedPasteboardOnly() async {
        let fake = Fake()
        let devices = AddDeviceFlowTests.Fake()
        var concealed: [String] = []
        var services = Self.services(devices, fake)
        services.copyConcealed = { concealed.append($0) }
        let model = fake.deviceModel(services)
        await model.begin(way: .joinLine)
        await model.joinLine?.mint()
        #expect(!model.perform(.copyJoinLine), "the card stays open after a copy")
        #expect(concealed == [fake.line.line])
        #expect(devices.copied.isEmpty, "never the plain copy that clipboard managers keep")
        #expect(model.joinLine?.copied == true)
    }

    @Test func flipsToJoinedWhenTheListCarriesItsJoinTokenId() async {
        let fake = Fake()
        let join = fake.model()
        await join.mint()
        #expect(fake.lists == 1, "the list is read once when the line shows")
        guard case .showing = join.phase else { Issue.record("not showing: \(join.phase)"); return }
        fake.rows = [Fake.joined("jt_other", name: "someone-else")]
        await join.refresh()
        guard case .showing = join.phase else { Issue.record("another line's machine flipped it"); return }
        fake.rows.append(Fake.joined("jt_1"))
        await join.refresh()
        #expect(join.phase == .joined(fake.line, Fake.joined("jt_1")))
        #expect(fake.doctors == ["m_lane-vm-3"], "the joined machine's checks run once")
        #expect(join.checks.map(\.step.rawValue) == ["heartbeat"])
        #expect(!join.isWatching, "the countdown and the mesh watch stop on the flip")
    }

    @Test func aMeshChangeReadsTheListAndNothingElseDoes() async throws {
        let fake = Fake()
        let join = fake.model()
        await join.mint()
        #expect(fake.lists == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.lists == 1, "no timer reads the list")
        fake.rows = [Fake.joined("jt_1")]
        for _ in 0..<1000 where fake.mesh == nil { await Task.yield() }
        let mesh = try #require(fake.mesh, "the mesh watch subscribed")
        mesh.yield()
        for _ in 0..<200 where join.line != nil { await Task.yield() }
        #expect(fake.lists == 2)
        if case .joined = join.phase {} else { Issue.record("a mesh change did not flip it: \(join.phase)") }
    }

    @Test func expiresAtExpiresAtAndNeverShowsTheLineAgain() async throws {
        let fake = Fake()
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(Self.services(devices, fake))
        await model.begin(way: .joinLine)
        let join = try #require(model.joinLine)
        await join.mint()
        fake.now = fake.now.addingTimeInterval(599.2)
        join.tick()
        #expect(join.secondsLeft == 1)
        fake.now = fake.now.addingTimeInterval(1)
        join.tick()
        #expect(join.phase == .expired)
        #expect(join.line == nil)
        #expect(!join.isWatching)
        #expect(model.buttons.map(\.action) == [.cancel, .newJoinLine])
        fake.line = JoinLine(line: " curl … | CMUX_JOIN=cmj_SECOND sh", joinTokenId: "jt_2", expiresAt: fake.now.addingTimeInterval(600))
        await join.mint()
        #expect(join.line?.joinTokenId == "jt_2", "New Line is a new mint")
    }

    @Test func closeStopsTheCountdownAndTheMeshWatch() async {
        let fake = Fake()
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(Self.services(devices, fake))
        await model.begin(way: .joinLine)
        await model.joinLine?.mint()
        #expect(model.joinLine?.isWatching == true)
        #expect(model.perform(.cancel))
        #expect(model.joinLine?.isWatching == false)
        #expect(model.joinLine?.phase == .idle)
        let lists = fake.lists
        await model.joinLine?.refresh()
        #expect(fake.lists == lists, "a focus after close reads nothing")
    }

    @Test func aFailedMintSaysWhyInTheAppsWords() async {
        let fake = Fake()
        fake.mintResult = .failure(.signedOut)
        let join = fake.model()
        await join.mint()
        #expect(join.phase == .failed(.signedOut))
        #expect(!AddDeviceStrings.joinLineFailed(.signedOut).contains("cmj_"))
        #expect(!join.isWatching)
    }

    @Test func joinedRowsDecodeFromTheMachineList() throws {
        let json = """
        [{"kind":"ssh","id":"ssh-1","name":"studio"},
         {"kind":"joined","id":"m_1","name":"lane-vm-3","state":"online","joinTokenId":"jt_1","mintedBy":"you@example.com","platform":"linux"},
         {"kind":"joined","machineId":"m_2","label":"old","state":"online","revoked":true},
         {"kind":"joined","id":"m_3","hostname":"box","state":"sleeping"},
         {"kind":"joined","name":"no-id"}]
        """
        let rows = try #require(JoinedMachine.list(from: Data(json.utf8)))
        #expect(rows.map(\.id) == ["m_1", "m_2", "m_3"])
        #expect(rows.map(\.state) == [.online, .revoked, .offline])
        #expect(rows.map(\.name) == ["lane-vm-3", "old", "box"])
        #expect(rows[0].mintedBy == "you@example.com")
        #expect(JoinedMachine.list(from: Data("{}".utf8)) == nil)
    }

    /// Online is the machine's own heartbeat within the hub's 90 s row TTL, read at `now`, whatever
    /// window the CLI used; RFC 3339 text and epoch milliseconds both read. No heartbeat: the CLI's word.
    @Test func aJoinedRowIsOnlineWhenItsHeartbeatIsWithinNinetySeconds() throws {
        let now = try #require(JoinLine.date("2026-11-05T12:00:00.000Z"))
        let ms = Int(now.timeIntervalSince1970 * 1000) - 30_000
        let json = """
        [{"kind":"joined","id":"m_1","state":"offline","lastHeartbeat":"2026-11-05T11:58:31.000Z"},
         {"kind":"joined","id":"m_2","state":"online","lastHeartbeat":"2026-11-05T11:58:29.000Z"},
         {"kind":"joined","id":"m_3","state":"offline","lastHeartbeat":\(ms)},
         {"kind":"joined","id":"m_4","state":"online"},
         {"kind":"joined","id":"m_5","lastHeartbeat":"2026-11-05T11:59:59Z","revoked":true}]
        """
        let rows = try #require(JoinedMachine.list(from: Data(json.utf8), now: now))
        #expect(rows.map(\.state) == [.online, .offline, .online, .online, .revoked])
    }

    @Test func aMintDecodesThePlatformsISOExpiry() throws {
        // The platform's exact shape: `Date.toISOString()`, milliseconds and Z.
        let mint = try #require(JoinLine.decode(Data(#"{"line":" curl x | CMUX_JOIN=cmj_A sh","token":"cmj_A","joinTokenId":"jt","expiresAt":"2026-10-29T03:30:00.123Z"}"#.utf8)))
        #expect(abs(mint.expiresAt.timeIntervalSince1970 - 1_793_244_600.123) < 0.0005)
        #expect(mint.joinTokenId == "jt")
        // Epoch milliseconds are not a time the platform sends: such a mint is unreadable.
        #expect(JoinLine.decode(Data(#"{"line":"l","joinTokenId":"jt","expiresAt":1793244600123}"#.utf8)) == nil)
        #expect(JoinLine.decode(Data(#"{"line":"l","expiresAt":"2026-10-29T03:30:00.123Z"}"#.utf8)) == nil)
    }

    /// ssh is not removed, only moved: Advanced opens the network way, which lists and adds as it did
    /// when it was the default; closing Advanced goes back to the way the card was on.
    @Test func advancedOpensTheSSHWayWhichStillAdds() async throws {
        let fake = Fake()
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(Self.services(devices, fake))
        await model.begin()
        model.choose(.code)
        #expect(model.perform(.toggleAdvanced) == false, "the disclosure keeps the card open")
        #expect(model.way == .network)
        #expect(model.showsAdvanced)
        #expect(model.available.map(\.name) == ["studio"])
        #expect(model.buttons.map(\.action) == [.cancel, .newCloudMachine, .otherComputer])
        let texts = AddDeviceFlowTests.texts(in: AddDeviceView(model: model))
        #expect(texts.contains(AddDeviceStrings.sshKeyHint), "the ssh way's body shows under Advanced")
        model.perform(.toggleAdvanced)
        #expect(model.way == .code, "closing Advanced goes back to the way it was on")
        model.perform(.toggleAdvanced)
        let studio = try #require(model.available.first)
        #expect(model.perform(.pick(studio)), "Add still hands off to Add Machine")
        #expect(devices.added.map(\.0) == ["studio.tail1234.ts.net"])
    }

    /// A caller that names the ssh way (`device.add way=network`, `machine.add`) still opens on it.
    @Test func askingForTheSSHWayOpensItUnderAdvanced() async {
        let fake = Fake()
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(Self.services(devices, fake))
        await model.begin(way: .network)
        #expect(model.way == .network)
        #expect(model.showsAdvanced)
        model.toggleAdvanced()
        #expect(model.way == .joinLine, "closed, it falls back to the default way")
    }

    static func services(_ devices: AddDeviceFlowTests.Fake, _ fake: Fake) -> AddDeviceServices {
        var services = devices.services()
        let join = fake.service()
        services.machineJoin = { join }
        return services
    }
}
