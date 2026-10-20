import Foundation

/// What this build of the app can do, from its Info.plist (`project.yml`).
public struct BuildCapabilities: Sendable, Equatable {
    /// The build is signed for push (`aps-environment`). Only TestFlight builds
    /// are: hand-installed builds use the team wildcard profile, which cannot
    /// carry push.
    public let push: Bool
    /// The build carries the Sign in with Apple entitlement. Only TestFlight
    /// builds do (the wildcard profile cannot), so only they show the
    /// "Continue with Apple" button: elsewhere it could only fail.
    public let appleSignIn: Bool

    public init(push: Bool, appleSignIn: Bool = false) {
        self.push = push
        self.appleSignIn = appleSignIn
    }

    public init(info: [String: Any]) {
        push = (info["CmuxMobilePush"] as? String) == "YES"
        appleSignIn = (info["CmuxMobileAppleSignIn"] as? String) == "YES"
    }

    public static let current = BuildCapabilities(info: Bundle.main.infoDictionary ?? [:])
}
