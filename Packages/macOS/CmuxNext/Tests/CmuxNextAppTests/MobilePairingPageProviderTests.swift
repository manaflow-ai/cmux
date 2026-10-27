@testable import CmuxNextApp
import CmuxNextMobileHost
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Mobile Pairing page reads and writes the switch the iPhone host follows
/// (`mobile.allowIPhoneConnections`), not the irx listener's `phone.allowConnections`, and sends no
/// QR code: the iPhone app opens no pairing link yet.
@MainActor @Suite struct MobilePairingPageProviderTests {
    /// A stand-in app: a signed-in account and one settings value the page writes.
    @MainActor final class Fake {
        var allowed = false
        var writes: [([String], JSONValue)] = []
        let host = IPhoneHostService()

        func provider() -> MobilePairingPageProvider {
            MobilePairingPageProvider(dependencies: .init(
                host: host, signedIn: { true }, account: { ("me@example.com", "user-1") },
                allowed: { [unowned self] in allowed }, macName: { "Studio" },
                write: { [unowned self] path, value in
                    writes.append((path, value))
                    if path == MobileSettings.allowIPhoneConnectionsPath { allowed = value.boolValue ?? false }
                }))
        }
    }

    @Test func theSwitchIsTheOneTheIPhoneHostFollows() {
        #expect(MobilePairingPageProvider.switchPath == ["mobile", "allowIPhoneConnections"])
        #expect(MobilePairingPageProvider.switchPath != SessionSettings.allowConnectionsPath)
    }

    @Test func turningOnWritesAllowIPhoneConnectionsAndTheStatusReadsIt() async throws {
        let fake = Fake()
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
        #expect(on["qr"] == nil, "no QR code until cmux on iPhone opens a pairing link")
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
}
