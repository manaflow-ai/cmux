// DEBUG builds only: no demo plumbing ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxDeviceHub
import CmuxScreenKit
import CmuxScreenKitUI
import CryptoKit
import Foundation
public import SwiftUI

/// `-CmuxMobileScreenSharingDemo`: the Screen Sharing viewer, with the same
/// chrome the real viewer shows, on the built-in demo desktop (a loopback
/// screen server in this app), so the viewer's controls can be tried and
/// UI-tested without a Mac.
public struct ScreenSharingDemoRoot: View {
    @State private var session = ScreenSession(demoPreferences: ScreenPreferences())

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileScreenSharingDemo") }

    public var body: some View {
        ScreenSessionView(session: session, features: ScreenSharingViewerScreen.features) {}
            .onAppear { session.connect() }
    }
}

/// `-CmuxMobileScreenSharingConnectDemo` (ui-state-fixes I3 capture): the real viewer card
/// for a Mac that never answers the request (the hub's answer is held forever), so the
/// connecting card's spinner shows and, after `ScreenSharingViewer.goAheadDeadline`, the
/// "Couldn't reach" card with Try Again. No hub is contacted.
public struct ScreenSharingConnectDemoRoot: View {
    @State private var viewer = ScreenSharingConnectDemoRoot.makeViewer()

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileScreenSharingConnectDemo") }

    public var body: some View {
        ScreenSharingViewerScreen(viewer: viewer, retry: { viewer.request(viewer.lastScope) }, close: {})
            .onAppear { viewer.request(.full) }
            // This root stands outside RootView, so it applies Settings › Appearance itself.
            .preferredColorScheme(Self.colorScheme)
    }

    static var colorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "cmuxMobile.settings.appearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    @MainActor static func makeViewer() -> ScreenSharingViewer {
        let identity = DeviceIdentity(deviceID: UUID(), keys: DemoKeys())
        let url = URL(string: "https://hub.invalid")!
        let client = DeviceHubClient(baseURL: url, identity: identity, tokens: DeviceHubAccountToken { "demo" })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "iPhone", platform: .ios)
        let viewer = ScreenSharingViewer(hostID: "demo-mac", hostName: "Demo Mac", hub: hub,
                                         preferences: ScreenSharingPreferences(store: UserDefaults(suiteName: "screen-sharing-connect-demo")!))
        // The Mac never answers: the request stays out until the go-ahead deadline.
        viewer.requestSession = { _, _, _ in
            let (answers, continuation) = AsyncStream<HubSession>.makeStream()
            DemoKeys.held.append(continuation)
            for await session in answers { return session }
            throw CancellationError()
        }
        viewer.endSession = { _, _, _ in }
        return viewer
    }
}

/// In-memory keys for the demo's identity (never stored).
private struct DemoKeys: DeviceKeyMaterial {
    @MainActor static var held: [AsyncStream<HubSession>.Continuation] = []
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
    func open(_: Data, encapsulatedKey _: Data, info _: Data) throws -> Data { Data() }
}
#endif
