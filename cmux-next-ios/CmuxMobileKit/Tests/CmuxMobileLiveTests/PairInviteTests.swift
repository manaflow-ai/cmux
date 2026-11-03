import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

/// A Mac's pairing code (`cmux-next://pair?…`, the Mac's `MobileHostPairInvite`):
/// parsed strictly, and its token goes only to the Mac that proved the key it names, once.
@Suite struct PairInviteTests {
    static let token = "AAECAwQFBgcICQoLDA0ODw"
    /// The Mac's identity key (fixed, so every test's code names the same key).
    static var macKey: P256.Signing.PrivateKey { try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)) }

    /// The code's text as the Mac builds it (URLComponents).
    static func url(mac: String = MacPinTests.mac, team: String = "team_1", name: String = "Leo's MacBook Pro", t: String? = token,
                    k: String? = keyHash(macKey), e: String? = "9999999999", scheme: String = "cmux-next",
                    host: String = "pair") -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "mac", value: mac), URLQueryItem(name: "team", value: team),
                                 URLQueryItem(name: "name", value: name)]
            + (t.map { [URLQueryItem(name: "t", value: $0)] } ?? []) + (k.map { [URLQueryItem(name: "k", value: $0)] } ?? [])
            + (e.map { [URLQueryItem(name: "e", value: $0)] } ?? [])
        return components.string!
    }

    static func keyHash(_ key: P256.Signing.PrivateKey) -> String {
        PairInvite.base64URL(Data(SHA256.hash(data: key.publicKey.x963Representation)))
    }

    @Test func aMacsCodeParses() throws {
        let invite = try #require(PairInvite(text: Self.url()))
        #expect(invite.mac == MacPinTests.mac)
        #expect(invite.team == "team_1")
        #expect(invite.name == "Leo's MacBook Pro")
        #expect(invite.token == Self.token)
        #expect(invite.names(key: ApprovalPayload.hex(Self.macKey.publicKey.x963Representation)))
        #expect(!invite.names(key: ApprovalPayload.hex(P256.Signing.PrivateKey().publicKey.x963Representation)))
        // Logs and descriptions never carry the token.
        #expect(!String(describing: invite).contains(Self.token))
        #expect(!"\(invite)".contains(Self.token))
        #expect(PairInvite(text: Self.url(name: String(repeating: "x", count: 90)))?.name.count == 64)
    }

    @Test func anythingElseIsRefused() {
        #expect(PairInvite(text: Self.url(scheme: "https")) == nil)
        #expect(PairInvite(text: Self.url(scheme: "cmux")) == nil)
        #expect(PairInvite(text: Self.url(host: "open")) == nil)
        #expect(PairInvite(text: Self.url(t: nil)) == nil)
        #expect(PairInvite(text: Self.url(k: nil)) == nil)
        #expect(PairInvite(text: Self.url(e: nil)) == nil)
        #expect(PairInvite(text: Self.url(e: "soon")) == nil)
        #expect(PairInvite(text: Self.url(e: "-1")) == nil)
        #expect(PairInvite(text: Self.url(mac: "")) == nil)
        #expect(PairInvite(text: Self.url(team: "")) == nil)
        #expect(PairInvite(text: "cmux-next://pair") == nil)
        #expect(PairInvite(text: "not a url") == nil)
        // Token: 16 to 64 base64url characters.
        #expect(PairInvite(text: Self.url(t: "short")) == nil)
        #expect(PairInvite(text: Self.url(t: String(repeating: "a", count: 65))) == nil)
        #expect(PairInvite(text: Self.url(t: "AAECAwQFBgcICQoLDA0OD+/")) == nil)
        // Key hash: a base64url SHA-256 (43 characters, 32 bytes).
        #expect(PairInvite(text: Self.url(k: String(Self.keyHash(Self.macKey).dropLast()))) == nil)
        #expect(PairInvite(text: Self.url(k: String(repeating: "=", count: 43))) == nil)
        #expect(PairInvite(text: Self.url(mac: "mac 1/../x")) == nil)
    }

    @Test func aCodeExpiresFiveMinutesAfterItArrived() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = try #require(PairInvite(text: Self.url(), now: start))
        #expect(!invite.isExpired(at: start.addingTimeInterval(299)))
        #expect(invite.isExpired(at: start.addingTimeInterval(300)))
    }

    /// A photo of an old code: the Mac's expiry (`e`) has passed, so it is expired on arrival.
    @Test func aCodeExpiresWhenTheMacsTokenDoes() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = try #require(PairInvite(text: Self.url(e: "1800000060"), now: start))
        #expect(!invite.isExpired(at: start.addingTimeInterval(59)))
        #expect(invite.isExpired(at: start.addingTimeInterval(60)))
        let old = try #require(PairInvite(text: Self.url(e: "1799999999"), now: start))
        #expect(old.isExpired(at: start))
    }

    /// The decode step: a QR image of a Mac's code reads back as the same text, and parses.
    @Test func aQRImageOfTheCodeReadsBack() throws {
        let text = Self.url()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let output = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        // A quiet zone around the code, as on screen.
        let framed = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -40, dy: -40)))
        let image = try #require(CIContext().createCGImage(framed, from: framed.extent))
        let payloads = PairInvite.payloads(in: image)
        #expect(payloads == [text])
        #expect(PairInvite(text: try #require(payloads.first))?.mac == MacPinTests.mac)
    }

    // MARK: Presenting the token

    static func pairing(_ invites: PairInvites) -> LinkPairing {
        let keys = PhoneKeys(userID: "u1", service: "test.invite.\(UUID())", store: MemorySecretStore(), enclave: false)
        return LinkPairing(keys: keys, phoneID: MacPinTests.phone, name: "iPhone", pins: MacPins(file: nil), invites: invites)
    }

    /// Runs one `auth` whose challenge is `frame`; the reply the phone sent.
    static func reply(_ pairing: LinkPairing, challenge frame: JSONValue, macID: String = MacPinTests.mac) async throws -> JSONValue? {
        let channel = RemoveThisPhoneUnpairTests.AuthChannel(frame)
        let opened = LinkPairing.Opened(channel: channel, identity: "04aa", approval: "04bb", macNonce: MacPinTests.phoneNonce)
        _ = await pairing.finish(.success(opened), macID: macID) {}
        return try channel.sent.first.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    @Test func theTokenGoesOnlyToTheMacThatProvedTheNamedKeyAndOnlyOnce() async throws {
        let invites = PairInvites()
        let pairing = Self.pairing(invites)
        invites.hold(try #require(PairInvite(text: Self.url())))
        let first = try #require(try await Self.reply(pairing, challenge: MacPinTests.challenge(Self.macKey)))
        #expect(first["pairToken"]?.stringValue == Self.token)
        #expect(first["signature"]?.stringValue != nil)
        // Used once: the next `auth` to the same Mac says nothing of it.
        #expect(invites.pending() == nil)
        let second = try #require(try await Self.reply(pairing, challenge: MacPinTests.challenge(Self.macKey, nonce: "c0ffee2")))
        #expect(second["pairToken"] == nil)
        // Opening the same code again holds nothing: its token was presented already.
        #expect(!invites.hold(try #require(PairInvite(text: Self.url()))))
        let third = try #require(try await Self.reply(pairing, challenge: MacPinTests.challenge(Self.macKey, nonce: "c0ffee3")))
        #expect(third["pairToken"] == nil)
    }

    @Test func aMacWithAnotherKeyOrNoProofNeverSeesTheTokenAndUsesTheCodeUp() async throws {
        for challenge in [MacPinTests.challenge(P256.Signing.PrivateKey()), MacPinTests.challenge(nil)] {
            let invites = PairInvites()
            invites.hold(try #require(PairInvite(text: Self.url())))
            let reply = try #require(try await Self.reply(Self.pairing(invites), challenge: challenge))
            #expect(reply["pairToken"] == nil)
            #expect(invites.pending() == nil)
        }
    }

    @Test func aCodeForAnotherMacStaysHeldAndIsNotSent() async throws {
        let invites = PairInvites()
        invites.hold(try #require(PairInvite(text: Self.url(mac: "mac-2"))))
        let reply = try #require(try await Self.reply(Self.pairing(invites), challenge: MacPinTests.challenge(Self.macKey)))
        #expect(reply["pairToken"] == nil)
        #expect(invites.pending(mac: "mac-2") != nil)
    }

    @Test func anExpiredCodeIsNotSent() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let invites = PairInvites(now: { start.addingTimeInterval(301) })
        invites.hold(try #require(PairInvite(text: Self.url(), now: start)))
        let reply = try #require(try await Self.reply(Self.pairing(invites), challenge: MacPinTests.challenge(Self.macKey)))
        #expect(reply["pairToken"] == nil)
        #expect(invites.pending() == nil)
    }

    /// `open` goes out before the Mac proves anything: it never carries the token.
    @Test func theOpenArgsNeverCarryTheToken() async throws {
        let invites = PairInvites()
        invites.hold(try #require(PairInvite(text: Self.url())))
        let link = RemoveThisPhoneUnpairTests.RecordingLink(RemoveThisPhoneUnpairTests.AuthChannel(MacPinTests.challenge(Self.macKey)))
        _ = await Self.pairing(invites).open(link: link, macID: MacPinTests.mac)
        let args = try #require(link.opened.first?.1)
        #expect(args["pairToken"] == nil)
        #expect(!args.values.contains { $0.contains(Self.token) })
        #expect(invites.pending() != nil)
    }
}

#if os(iOS)
/// The coordinator takes a code only for a space this account is in and only while it is live;
/// a taken code is held for its Mac's challenge, and that Mac is the one the team's Macs focus.
@MainActor
@Suite(.serialized) struct PairInviteCoordinatorTests {
    func coordinator(_ store: AppStore) -> LiveCoordinator {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-invite-\(UUID().uuidString)")
        let secrets = MemorySecretStore()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: "user-a", deviceName: "iPhone", transport: .webRTC, dialer: MockDialer(fail: true),
            feedStore: FeedStore(items: []),
            keys: PhoneKeys(userID: "user-a", service: "test.invite.\(UUID())", store: secrets, enclave: false),
            snapshots: LiveSnapshotStore(directory: directory), secrets: secrets,
            readMarks: FeedReadMarks(url: directory.appending(path: "read.json"))
        )
    }

    @Test func aCodeForThisAccountsSpaceIsHeldForItsMac() throws {
        let key = "cmuxMobile.live.mac.t1"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = AppStore(teams: [Team(id: "t1", name: "One")], activeTeamID: "t1", workspaces: [], feed: [],
                             tabMemory: .inMemory())
        let live = coordinator(store)
        defer { live.stop() }
        let invite = try #require(PairInvite(text: PairInviteTests.url(mac: "m1", team: "t1")))
        #expect(live.accept(invite))
        #expect(live.pairing?.invites.pending(mac: "m1") == invite)
        #expect(UserDefaults.standard.string(forKey: key) == "m1")
    }

    @Test func aCodeForAnotherSpaceOrAnExpiredOneIsRefused() throws {
        let store = AppStore(teams: [Team(id: "t1", name: "One")], activeTeamID: "t1", workspaces: [], feed: [],
                             tabMemory: .inMemory())
        let live = coordinator(store)
        defer { live.stop() }
        let stranger = try #require(PairInvite(text: PairInviteTests.url(mac: "m9", team: "t9")))
        #expect(!live.accept(stranger))
        let old = try #require(PairInvite(text: PairInviteTests.url(mac: "m1", team: "t1"),
                                          now: Date().addingTimeInterval(-PairInvite.lifetime - 1)))
        #expect(!live.accept(old))
        #expect(live.pairing?.invites.pending() == nil)
    }

    /// A code taken before the account's spaces loaded moves nothing, and is dropped once they
    /// load without its space.
    @Test func aCodeTakenBeforeTheSpacesLoadIsCheckedWhenTheyDo() throws {
        let key = "cmuxMobile.live.mac.t9"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = coordinator(store)
        defer { live.stop() }
        let invite = try #require(PairInvite(text: PairInviteTests.url(mac: "m9", team: "t9")))
        #expect(live.accept(invite))
        #expect(store.activeTeamID == "")
        #expect(UserDefaults.standard.string(forKey: key) == nil)
        store.teams = [Team(id: "t1", name: "One")]
        live.steerToInvite()
        #expect(live.pairing?.invites.pending() == nil)
        #expect(store.activeTeamID != "t9")
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    /// A code from the other build on a listed computer (MacRoster lists one build per computer)
    /// dials that build, though the listed one keeps the focus, even while every link is taken.
    @Test func aCodeFromTheOtherBuildOnAComputerDialsThatBuild() async throws {
        let userID = "user-a", teamID = "t-hidden-\(UUID().uuidString.prefix(8))"
        let pick = "cmuxMobile.live.mac.\(teamID)"
        defer { UserDefaults.standard.removeObject(forKey: pick) }
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        // m1 to m5 on five computers fill the four links Workspaces keeps; m1b is m1's other build.
        let macs = [
            MacDevice(id: "m1", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
            MacDevice(id: "m1b", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
        ] + (2...5).map {
            MacDevice(id: "m\($0)", name: "Mac \($0)", isOnline: true, ownerUserID: userID, machineID: String(repeating: "\($0)", count: 32))
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-invite-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(
            teamID: teamID, teamName: "One", macs: macs, linkedMacID: "m1",
            workspaces: Dictionary(uniqueKeysWithValues: macs.map { ($0.id, .init(workspaces: [], savedAt: Date())) })
        ), accountID: userID)
        snapshots.flush()
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let secrets = MemorySecretStore()
        let dialer = PerMacDialer()
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: dialer,
            feedStore: FeedStore(items: []),
            keys: PhoneKeys(userID: userID, service: "test.invite.\(UUID())", store: secrets, enclave: false),
            snapshots: snapshots, secrets: secrets,
            readMarks: FeedReadMarks(url: directory.appending(path: "read.json"))
        )
        defer { live.stop() }
        live.showing(macIDs: nil)
        for _ in 0..<3000 where store.macConnection["m1"] != .connected { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(MacRoster(store.activeTeam?.macs ?? []).visible.map(\.id) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(dialer.dialCount("m1b") == 0)
        let invite = try #require(PairInvite(text: PairInviteTests.url(mac: "m1b", team: teamID)))
        #expect(live.accept(invite))
        for _ in 0..<3000 where dialer.dialCount("m1b") == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(dialer.dialCount("m1b") > 0)
        #expect(live.focusedMacID == "m1")
    }
}
#endif
