public import CmuxAppAttest
public import CmuxNextCompat
public import CmuxNextSettings
public import CmuxNextWakeups
import DeviceCheck
public import Foundation
import os

/// Composes and runs the app's App Attest provider for the local model relay
/// (cx-ds09i; the relay owns the free-tier lease, ``FreeTierAttestProvider``).
/// It follows `freeModel.enabled`, whether a profile or team policy sets it,
/// and the sign-in (a signed-in Mac never takes a free lease). The relay
/// starts a lease only at the first signed-out agent request, never here.
///
/// The app keeps only the hook (one call at launch) and the token it returns, for its
/// lifetime; the provider lives as long as the app, and its connection ends with the
/// process, so the relay drops the free token at once:
///
/// ```swift
/// lifetimeFollowers.append(FreeTierAttestStarter(build: build, bundle: .main, apiBaseURL: url, settings: settings,
///                       signedIn: { cloud.isSignedIn || cloud.auth.isRestoring }).start(on: mainWork))
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

    /// What the provider follows; a change of any starts one update.
    nonisolated struct Inputs: Equatable, Sendable {
        var enabled: Bool
        var managed: Bool
        var signedIn: Bool
    }

    /// What the provider is told, in order: one start with the first inputs, one update per change, and a stop
    /// when the follow ends.
    nonisolated enum Step: Equatable, Sendable {
        case start(Inputs)
        case update(Inputs)
        case stop
    }

    /// Starts the provider and follows the setting and the sign-in while the returned token is
    /// held (the app holds it for its lifetime). Nil without acpmux or an API origin.
    ///
    /// The follow is a `background` service observation on `work` (nobody sees the lease, and the
    /// relay reads it off main); each change goes, in order and coalesced to the newest, to one task
    /// off main that calls the provider actor.
    ///
    /// - Parameter work: The app's one main-thread scheduler (`AppServices.mainWork`).
    public func start(on work: MainWorkScheduler) -> AnyObject? {
        let bin = bundle.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin,
                                                     environment: ProcessInfo.processInfo.environment),
              let scheme = apiBaseURL.scheme, let host = apiBaseURL.host else { return nil }
        // Scheme, host and port only; the relay accepts only a known cmux API origin.
        let origin = "\(scheme)://\(host)" + (apiBaseURL.port.map { ":\($0)" } ?? "")
        let provider = FreeTierAttestProvider(
            environment: acpmux, attest: AppleDeviceAttest(service: .shared, device: .current),
            // One item per app: Release, NIGHTLY and DEV builds never share an App Attest key id
            // (another build's id is an invalid key here and would spend this Mac's monthly grant).
            keys: KeychainAttestKeyStore(service: "com.cmuxterm.next.free-tier.app-attest.\(bundle.bundleIdentifier ?? "unknown")",
                                         account: "key"),
            logger: Logger(subsystem: "com.cmuxterm.app.next", category: "free-tier"))
        return Self.follow(settings: settings, signedIn: signedIn, on: work) { step in
            switch step {
            case .start(let inputs):
                await provider.start(origin: origin, enabled: inputs.enabled, managed: inputs.managed, signedIn: inputs.signedIn)
            case .update(let inputs):
                await provider.update(enabled: inputs.enabled, managed: inputs.managed, signedIn: inputs.signedIn)
            case .stop:
                await provider.stop()
            }
        }
    }

    /// Follows the setting and the sign-in in a `background` service observation on `work`, and hands each change,
    /// in order and coalesced to the newest, to `run` in one task off main. The returned token holds the follow.
    static func follow(settings: SettingsController?, signedIn: @escaping @MainActor () -> Bool, on work: MainWorkScheduler,
                       run: @escaping @Sendable (Step) async -> Void) -> AnyObject {
        let (changes, feed) = AsyncStream.makeStream(of: Inputs.self, bufferingPolicy: .bufferingNewest(1))
        // task-owner: lives as long as the follow (the app's lifetime); one provider start, then one update per change
        Task { @concurrent in
            var started = false
            for await inputs in changes {
                await run(started ? .update(inputs) : .start(inputs))
                started = true
            }
            await run(.stop)
        }
        return ServiceObservation(.background, owner: "FreeTierAttestStarter.inputs", on: work) {
            Inputs(enabled: settings?.snapshot.freeModel.enabled ?? true, managed: settings?.managedKeys["freeModel.enabled"] != nil,
                   signedIn: signedIn())
        } apply: { inputs in
            feed.yield(inputs)
        }
    }
}
