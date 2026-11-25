public import CmuxAppAttest
public import CmuxNextCompat
public import CmuxNextSettings
import DeviceCheck
public import Foundation
import os

/// Composes and runs the app's App Attest provider for the local model relay
/// (cx-ds09i; the relay owns the free-tier lease, ``FreeTierAttestProvider``).
/// It follows `freeModel.enabled`, whether a profile or team policy sets it,
/// and the sign-in (a signed-in Mac never takes a free lease). The relay
/// starts a lease only at the first signed-out agent request, never here.
///
/// The app keeps only the hook (one call at launch; the provider lives as
/// long as the app, and its connection ends with the process, so the relay
/// drops the free token at once):
///
/// ```swift
/// FreeTierAttestStarter(build: build, bundle: .main, apiBaseURL: url, settings: settings,
///                       signedIn: { cloud.isSignedIn || cloud.auth.isRestoring }).start()
/// ```
@MainActor public struct FreeTierAttestStarter {
    private let build: BuildIdentity?
    private let bundle: Bundle
    private let apiBaseURL: URL
    private let settings: SettingsController?
    private let signedIn: @MainActor () -> Bool

    /// - Parameter build: the app's build (its acpmux home, per-build isolation cx-is1kf).
    /// - Parameter bundle: the app bundle (bundled acpmux, bundle id for the keychain item).
    /// - Parameter apiBaseURL: the cmux API base URL; the relay sends the free token only to its origin.
    /// - Parameter settings: `freeModel.enabled` and its managed lock.
    /// - Parameter signedIn: an account is signed in, or a session is still restoring.
    public init(build: BuildIdentity?, bundle: Bundle, apiBaseURL: URL, settings: SettingsController?,
                signedIn: @escaping @MainActor () -> Bool) {
        self.build = build
        self.bundle = bundle
        self.apiBaseURL = apiBaseURL
        self.settings = settings
        self.signedIn = signedIn
    }

    /// Starts the provider and follows the setting and the sign-in for the
    /// app's lifetime. Does nothing without acpmux or an API origin.
    public func start() {
        let bin = bundle.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin,
                                                     environment: ProcessInfo.processInfo.environment),
              let scheme = apiBaseURL.scheme, let host = apiBaseURL.host else { return }
        // Scheme, host and port only; the relay accepts only a known cmux API origin.
        let origin = "\(scheme)://\(host)" + (apiBaseURL.port.map { ":\($0)" } ?? "")
        let provider = FreeTierAttestProvider(
            environment: acpmux, attest: AppleDeviceAttest(service: .shared, device: .current),
            // One item per app: Release, NIGHTLY and DEV builds never share an App Attest key id
            // (another build's id is an invalid key here and would spend this Mac's monthly grant).
            keys: KeychainAttestKeyStore(service: "com.cmuxterm.next.free-tier.app-attest.\(bundle.bundleIdentifier ?? "unknown")",
                                         account: "key"),
            logger: Logger(subsystem: "com.cmuxterm.next", category: "free-tier"))
        let settings = settings, signedIn = signedIn
        // task-owner: lives as long as the app (the provider's connection ends with the process); one provider start, then one update per setting or sign-in change
        Task {
            var started = false
            for await (enabled, managed, signedIn) in ObservationStream({
                (settings?.snapshot.freeModel.enabled ?? true, settings?.managedKeys["freeModel.enabled"] != nil, signedIn())
            }) {
                if started {
                    await provider.update(enabled: enabled, managed: managed, signedIn: signedIn)
                } else {
                    started = true
                    await provider.start(origin: origin, enabled: enabled, managed: managed, signedIn: signedIn)
                }
            }
            await provider.stop()
        }
    }
}
