import AppKit
@testable import CmuxNextApp
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextPages
import CmuxNextSettings
import CoreImage
import Foundation
import Testing

/// The Mobile Pairing page reads and writes the switch the iPhone host follows
/// (`mobile.allowIPhoneConnections`), not the irx listener's `phone.allowConnections`, and shows
/// this Mac's pairing link as a QR code only once the host is online.
@MainActor @Suite struct MobilePairingPageProviderTests {
    /// A stand-in app: a signed-in account and one settings value the page writes.
    @MainActor final class Fake {
        var allowed = false
        var writes: [([String], JSONValue)] = []
        var invite: MobileHostPairInvite?
        let host = IPhoneHostService()

        func provider() -> MobilePairingPageProvider {
            MobilePairingPageProvider(dependencies: .init(
                host: host, signedIn: { true }, account: { ("me@example.com", "user-1") },
                allowed: { [unowned self] in allowed }, macName: { "Studio" },
                write: { [unowned self] path, value in
                    writes.append((path, value))
                    if path == MobileSettings.allowIPhoneConnectionsPath { allowed = value.boolValue ?? false }
                },
                invite: { [unowned self] _ in invite }))
        }
    }

    @Test func theSwitchIsTheOneTheIPhoneHostFollows() {
        #expect(MobilePairingPageProvider.switchPath == ["mobile", "allowIPhoneConnections"])
        #expect(MobilePairingPageProvider.switchPath != SessionSettings.allowConnectionsPath)
    }

    static let invite = MobileHostPairInvite(
        macDeviceID: "mac-1", teamID: "team-1", macName: "Studio", token: "AbC-dEf_0123456789",
        macPublicKey: Data([0x04] + [UInt8](repeating: 7, count: 64)), expiresAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func turningOnWritesAllowIPhoneConnectionsAndTheStatusReadsIt() async throws {
        let fake = Fake()
        fake.invite = Self.invite
        let provider = fake.provider()
        let off = try await provider.call(MobilePairingPageProvider.statusOp, params: .object([:]), context: PageCallContext(page: "cmux.mobile-pairing"))
        #expect(off["state"] == .string("accessOff"))
        #expect(off["allowed"] == .bool(false))

        _ = try await provider.call(MobilePairingPageProvider.setAllowedOp, params: ["on": true],
                                    context: PageCallContext(page: "cmux.mobile-pairing", userGesture: true))
        #expect(fake.writes.map { $0.0 } == [MobileSettings.allowIPhoneConnectionsPath])
        #expect(fake.writes.map { $0.1 } == [.bool(true)])

        let on = try await provider.call(MobilePairingPageProvider.statusOp, params: .object([:]), context: PageCallContext(page: "cmux.mobile-pairing"))
        #expect(on["allowed"] == .bool(true))
        // The host has not started (no hostd in a test): the page waits for it.
        #expect(on["state"] == .string("preparing"))
        #expect(on["account"] == .string("me@example.com"))
        #expect(on["macName"] == .string("Studio"))
        #expect(on["qr"] == nil, "no QR code until the host is online")
        #expect(on["host"]?["how"]?.stringValue?.contains("sign in with the same account") == true)
        #expect(on["host"]?["pending"] == .array([]))
    }

    @Test func onlyThePersonsGestureWritesTheSwitch() async {
        let fake = Fake()
        let provider = fake.provider()
        await #expect(throws: PageError.self) {
            _ = try await provider.call(MobilePairingPageProvider.setAllowedOp, params: ["on": true],
                                        context: PageCallContext(page: "cmux.mobile-pairing"))
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func answeringAPairingRequestNeedsTheGestureAndAWaitingRequest() async {
        let fake = Fake()
        let provider = fake.provider()
        do {
            _ = try await provider.call(MobilePairingPageProvider.answerPairOp, params: ["id": "phone-1", "allow": true],
                                        context: PageCallContext(page: "cmux.mobile-pairing"))
            Issue.record("answered without the person's gesture")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        } catch { Issue.record("\(error)") }
        do {
            _ = try await provider.call(MobilePairingPageProvider.answerPairOp, params: ["id": "phone-1", "allow": true],
                                        context: PageCallContext(page: "cmux.mobile-pairing", userGesture: true))
            Issue.record("answered a request that does not wait")
        } catch let error as PageError {
            #expect(error.code == "cmux.protocol.invalid_params")
        } catch { Issue.record("\(error)") }
    }

    /// The code is the pairing link itself, and the page asks for a new one a minute before the
    /// token expires.
    @Test func theCodeReadsBackAsThePairingLink() throws {
        let qr = try #require(MobilePairingPageProvider.qr(Self.invite))
        #expect(qr["url"] == .string(Self.invite.url))
        #expect(Self.invite.url.hasPrefix("cmux-next://pair?mac=mac-1&team=team-1&name=Studio&t=AbC-dEf_0123456789&k="))
        #expect(qr["expiresAt"]?.intValue == 1_800_000_000_000 - 60_000)
        let image = try #require(qr["image"]?.stringValue)
        let prefix = "data:image/png;base64,"
        #expect(image.hasPrefix(prefix))
        let png = try #require(Data(base64Encoded: String(image.dropFirst(prefix.count))))
        let bitmap = try #require(NSBitmapImageRep(data: png)?.cgImage)
        // The code is drawn one pixel per module; scale it up so the detector reads it.
        let scaled = CIImage(cgImage: bitmap).samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let read = detector.features(in: scaled).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(read == [Self.invite.url])
    }
}
