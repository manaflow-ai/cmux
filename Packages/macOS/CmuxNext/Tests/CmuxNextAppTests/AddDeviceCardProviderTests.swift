import CmuxNextPages
@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing

/// The Add Device card's provider (`cmux.addDevice.*`, AddDeviceCardProvider): each opening is a new
/// session with what the app offers; every action and the mint need the person's own click or key;
/// the join line is copied concealed by the host (the page never sends it back); `joined` finds the
/// row carrying the shown line's `joinTokenId` and stops the mesh watch; a close drops the line. The
/// card's own flow (ways, buttons, countdown) is the page's (bun: addDevice/model.test.ts).
@MainActor @Suite(.serialized) struct AddDeviceCardProviderTests {
    nonisolated final class Fake: @unchecked Sendable {
        var listing: DeviceListing? = DeviceListing(network: .init(kind: "tailscale", up: true),
                                                    available: [.init(name: "studio", address: "studio.ts.net", os: "macOS", mine: true)])
        var added: [(String, String)] = []
        var codes = 0
        var copied: [String] = []
        var concealed: [String] = []
        var invites = 0
        var mints: [String?] = []
        /// Holds each mint until released, oldest first (overlapping mints).
        var held: [CheckedContinuation<Void, Never>] = []
        var holdMints = false
        var expiresIn: TimeInterval = 600
        var minted = 0
        var rows: [JoinedMachine] = []
        var mesh: AsyncStream<Void>.Continuation?
        var offersJoin = true
        var signedIn = false
        var line: JoinLine {
            JoinLine(line: " curl -fsSL https://cmux.example/v1/machines/join.sh | CMUX_JOIN=cmj_TESTTOKEN\(minted) sh",
                     joinTokenId: "jt_\(minted)", expiresAt: Date().addingTimeInterval(expiresIn))
        }

        @MainActor func services() -> AddDeviceServices {
            let join = MachineJoinService(
                mint: { [self] name in
                    mints.append(name)
                    if holdMints { await withCheckedContinuation { held.append($0) } }
                    minted += 1
                    return .success(line)
                },
                list: { [self] in rows },
                doctor: { _ in [HostStepResult(step: HostStep(rawValue: "heartbeat"), state: .ok)] },
                meshChanges: { [self] in AsyncStream { mesh = $0 } })
            return AddDeviceServices(
                list: { [self] in listing },
                addComputer: { [self] in added.append(($0, $1)) },
                addByName: {}, enterCode: { [self] in codes += 1 },
                copy: { [self] in copied.append($0) },
                machineJoin: { [self] in offersJoin ? join : nil },
                copyConcealed: { [self] in concealed.append($0) },
                pairAnotherMachine: { [self] () -> (() -> Void)? in
                    guard signedIn else { return nil }
                    return { self.invites += 1 }
                })
        }
    }

    static let gesture = PageCallContext(page: "cmux.server-cards", userGesture: true, gestureEvent: 1)
    static let script = PageCallContext(page: "cmux.server-cards")

    func provider(_ fake: Fake) -> AddDeviceCardProvider {
        AddDeviceCardProvider(services: fake.services(), panel: { nil }, personOnlyMessage: "click")
    }

    @Test func eachOpeningIsANewSessionWithWhatTheAppOffers() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.opened(again: false)
        var status = try await provider.call(AddDeviceCardProvider.statusOp, params: .null, context: Self.script)
        #expect(status["open"]?.boolValue == true)
        #expect(status["join"]?.boolValue == true)
        #expect(status["invite"]?.boolValue == false, "signed out: the ticket line")
        let first = status["session"]
        fake.signedIn = true
        provider.opened(again: true)
        status = try await provider.call(AddDeviceCardProvider.statusOp, params: .null, context: Self.script)
        #expect(status["session"] != first)
        #expect(status["invite"]?.boolValue == true)
        fake.offersJoin = false
        provider.opened(again: true)
        status = try await provider.call(AddDeviceCardProvider.statusOp, params: .null, context: Self.script)
        #expect(status["join"]?.boolValue == false)
        #expect(status["invite"]?.boolValue == false, "no invite without the join way")
        provider.closed()
        status = try await provider.call(AddDeviceCardProvider.statusOp, params: .null, context: Self.script)
        #expect(status["open"]?.boolValue == false)
    }

    @Test func theListingReachesThePage() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.opened(again: false)
        let listing = try await provider.call(AddDeviceCardProvider.listOp, params: .null, context: Self.script)
        #expect(listing["available"]?.arrayValue?.first?["address"]?.stringValue == "studio.ts.net")
        fake.listing = nil
        #expect(try await provider.call(AddDeviceCardProvider.listOp, params: .null, context: Self.script) == .null)
    }

    @Test func everyActionAndTheMintNeedThePersonsClickOrKey() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.opened(again: false)
        for (op, params) in [("cmux.addDevice.mint", JSONValue.object([:])), ("cmux.addDevice.enterCode", .null),
                             ("cmux.addDevice.addComputer", ["address": "studio.ts.net", "name": "studio"]),
                             ("cmux.addDevice.copySetupLine", ["platform": "windows"])] {
            await #expect(throws: PageError.self) { try await provider.call(op, params: params, context: Self.script) }
        }
        #expect(fake.mints.isEmpty && fake.codes == 0 && fake.added.isEmpty && fake.copied.isEmpty)
        _ = try await provider.call("cmux.addDevice.addComputer", params: ["address": "studio.ts.net", "name": "studio"], context: Self.gesture)
        #expect(fake.added.map(\.0) == ["studio.ts.net"])
        _ = try await provider.call(AddDeviceCardProvider.copySetupLineOp, params: ["platform": "windows"], context: Self.gesture)
        #expect(fake.copied == [AddDeviceCardProvider.setupLines["windows"]!])
        #expect(AddDeviceCardProvider.setupLines["macOrLinux"]?.hasSuffix("cmux server pair") == true)
    }

    @Test func theLineIsCopiedConcealedByTheHostAndJoinedFindsItsMachine() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.opened(again: false)
        let minted = try await provider.call(AddDeviceCardProvider.mintOp, params: ["name": "  lane-vm-3 "], context: Self.gesture)
        #expect(fake.mints == ["lane-vm-3"])
        #expect(minted["line"]?["joinTokenId"]?.stringValue == "jt_1")
        let shownLine = try #require(minted["line"]?["line"]?.stringValue)
        #expect(provider.isWatching, "the mesh watch runs while the line shows")
        _ = try await provider.call(AddDeviceCardProvider.copyJoinLineOp, params: .null, context: Self.gesture)
        #expect(fake.concealed == [shownLine])
        #expect(fake.copied.isEmpty, "never the plain copy that clipboard managers keep")
        #expect(try await provider.call(AddDeviceCardProvider.joinedOp, params: .null, context: Self.script) == .null)
        fake.rows = [JoinedMachine(id: "m_other", name: "other", state: .online, joinTokenId: "jt_other"),
                     JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, joinTokenId: "jt_1")]
        let joined = try await provider.call(AddDeviceCardProvider.joinedOp, params: .null, context: Self.script)
        #expect(joined["id"]?.stringValue == "m_1")
        #expect(!provider.isWatching, "the flip stops the mesh watch")
        let checks = try await provider.call(AddDeviceCardProvider.doctorOp, params: .null, context: Self.script)
        #expect(checks.arrayValue?.first?["title"]?.stringValue == "Check in with cmux")
    }

    @Test func aCloseDropsTheLineAndStopsTheWatch() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.opened(again: false)
        _ = try await provider.call(AddDeviceCardProvider.mintOp, params: .null, context: Self.gesture)
        provider.closed()
        #expect(!provider.isWatching)
        await #expect(throws: PageError.self) {
            try await provider.call(AddDeviceCardProvider.copyJoinLineOp, params: .null, context: Self.gesture)
        }
        #expect(fake.concealed.isEmpty)
    }

    @Test func pairAnotherMachineIsOfferedOnlySignedIn() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.opened(again: false)
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.addDevice.pairAnotherMachine", params: .null, context: Self.gesture)
        }
        fake.signedIn = true
        provider.opened(again: true)
        _ = try await provider.call("cmux.addDevice.pairAnotherMachine", params: .null, context: Self.gesture)
        #expect(fake.invites == 1)
    }

    /// Two mints in flight: only the newer one's line shows, and Copy Line copies that one.
    @Test func anOlderMintsReplyIsDroppedSoTheCopyIsTheLineShown() async throws {
        let fake = Fake()
        fake.holdMints = true
        let provider = provider(fake)
        provider.opened(again: false)
        let first = Task { try await provider.call(AddDeviceCardProvider.mintOp, params: .null, context: Self.gesture) }
        for _ in 0..<1000 where fake.held.count < 1 { await Task.yield() }
        let second = Task { try await provider.call(AddDeviceCardProvider.mintOp, params: .null, context: Self.gesture) }
        for _ in 0..<1000 where fake.held.count < 2 { await Task.yield() }
        fake.held[0].resume()
        let older = try await first.value
        #expect(older["line"] == nil, "the older mint shows nothing")
        fake.held[1].resume()
        let newer = try await second.value
        _ = try await provider.call(AddDeviceCardProvider.copyJoinLineOp, params: .null, context: Self.gesture)
        #expect(fake.concealed == [try #require(newer["line"]?["line"]?.stringValue)])
    }

    /// At its expiry the line is gone on this side too: no copy, no watch.
    @Test func anExpiredLineIsDroppedAndItsWatchStops() async throws {
        let fake = Fake()
        fake.expiresIn = 0.05
        let provider = provider(fake)
        provider.opened(again: false)
        _ = try await provider.call(AddDeviceCardProvider.mintOp, params: .null, context: Self.gesture)
        #expect(provider.isWatching)
        for _ in 0..<200 where provider.isWatching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!provider.isWatching)
        await #expect(throws: PageError.self) {
            try await provider.call(AddDeviceCardProvider.copyJoinLineOp, params: .null, context: Self.gesture)
        }
    }

    #if DEBUG
    /// A capture's mint skips the gesture once; the next needs the person again.
    @Test func theCaptureMintIsOneShot() async throws {
        let fake = Fake()
        let provider = provider(fake)
        provider.debugMintName = "build-box"
        provider.opened(again: false)
        _ = try await provider.call(AddDeviceCardProvider.mintOp, params: ["name": "build-box"], context: Self.script)
        #expect(fake.mints == ["build-box"])
        let status = try await provider.call(AddDeviceCardProvider.statusOp, params: .null, context: Self.script)
        #expect(status["mintName"] == nil)
        await #expect(throws: PageError.self) {
            try await provider.call(AddDeviceCardProvider.mintOp, params: .null, context: Self.script)
        }
    }
    #endif
}
