public import CmuxNextCompat
public import CmuxNextMobile
public import Foundation

/// Dev builds only (DEBUG, a tagged `com.cmuxterm.app.debug.<tag>` bundle): the same tag's
/// iPhone app (`dev.cmux.mobile.<tag>`) of the signed-in account pairs without the person-only
/// "Allow … to connect?" prompt, as Allow would (cmux-next-ios/SECURITY.md "Dev auto-approve").
/// A machine, another tag's or another app's phone, or one that names no bundle id still asks.
///
/// On by default in a tagged dev build. `CMUX_NEXT_IPHONE_APPROVE_FIRST=1` in the launch
/// environment turns it off, so the prompt shows (`cmux-next-ios/scripts/review.sh --approve-first`).
/// A Release build compiles none of it; NIGHTLY, RC, staging and release bundle ids never get one.
///
/// Its other half holds in every build: a dev iPhone app's request to any Mac but its own tag's
/// dev build (NIGHTLY, stable, another tag) asks quietly (``asksQuietly(_:macDevTag:)``): no prompt,
/// banner or Dock bounce, only a waiting row in Settings > Mobile. A phone signed in to the
/// account dials the Macs it lists, which can be another build on the same computer, and the
/// person running a dev phone never meant to pair it there (2026-11-17, tag `ios-onboard`).
///
/// The rules are Rust's (`cmux-mobile-host-core` `dev_auto_approve`, the app FFI's `mobile_host` ops
/// `dev_auto_approve` and `dev_request`); this reads the bundle and the launch environment.
public nonisolated struct IPhoneDevAutoApprove: Sendable, Equatable {
    /// The launch variable that keeps the Allow prompt (`1`).
    public static let approveFirstKey = "CMUX_NEXT_IPHONE_APPROVE_FIRST"
    /// The bundle id prefix of a tagged dev iPhone app; the rest is its tag's slug.
    public static let phoneBundlePrefix = "dev.cmux.mobile."

    /// This Mac build's tag slug (``BuildIdentity/tag``); the phone app must carry the same one.
    public let tag: String

    /// The auto-approve of `build`, nil unless it is a tagged dev build in a DEBUG binary and the
    /// launch did not ask for the prompt (`environment`).
    init?(build: BuildIdentity, environment: [String: String], debugBuild: Bool) {
        var fields = Self.buildFields(build)
        fields["approveFirst"] = environment[Self.approveFirstKey]
        fields["debugBuild"] = debugBuild
        guard let tag = MobileHostRules.ask("dev_auto_approve", fields)?["tag"] as? String else { return nil }
        self.tag = tag
    }

    /// The tag of a tagged dev build (`com.cmuxterm.app.debug.<tag>`); nil for every other build.
    static func devTag(of build: BuildIdentity) -> String? {
        var fields = buildFields(build)
        fields["debugBuild"] = false
        return MobileHostRules.ask("dev_auto_approve", fields)?["devTag"] as? String
    }

    private static func buildFields(_ build: BuildIdentity) -> [String: Any] {
        var fields: [String: Any] = ["kind": build.kind.rawValue]
        fields["bundleId"] = build.bundleID
        fields["tag"] = build.tag
        return fields
    }

    /// The running app's dev tag (any configuration): nil unless it is a tagged dev build.
    public static func macDevTag(bundle: Bundle = .main) -> String? {
        devTag(of: BuildIdentity(bundle: bundle))
    }

    /// The `dev_request` answer for `request`: its phone tag, whether it asks quietly on a Mac of
    /// dev tag `macDevTag`, and whether auto-approve tag `autoTag` takes it for these users.
    static func ask(_ request: MobileHostPairRequest, macDevTag: String? = nil, autoTag: String? = nil,
                    pairedUserID: String = "", accountUserID: String? = nil) -> [String: Any]? {
        var fields: [String: Any] = ["kind": request.kind, "pairedUserId": pairedUserID]
        fields["bundleId"] = request.bundleID
        fields["macDevTag"] = macDevTag
        fields["autoTag"] = autoTag
        fields["accountUserId"] = accountUserID
        return MobileHostRules.ask("dev_request", fields)
    }

    /// The tag of the dev iPhone app (`dev.cmux.mobile.<tag>`) that sent `request`; nil for a
    /// machine, another app (the App Store or TestFlight build) or a request that names none.
    public static func phoneTag(of request: MobileHostPairRequest) -> String? {
        ask(request)?["phoneTag"] as? String
    }

    /// Whether `request` waits without the prompt, banner or Dock bounce on a Mac whose dev tag is
    /// `macDevTag` (nil: not a tagged dev build): a dev iPhone app of another tag, or any dev iPhone
    /// app on NIGHTLY, RC or release. The same tag (with `--approve-first`) and every other phone ask as before.
    public static func asksQuietly(_ request: MobileHostPairRequest, macDevTag: String?) -> Bool {
        ask(request, macDevTag: macDevTag)?["asksQuietly"] as? Bool ?? false
    }

    /// This launch's auto-approve: the running app's bundle (its id and the `CMUX_TAG` it ships,
    /// never the process environment's) and `environment`'s opt-out. Nil in a Release build.
    public static func fromLaunch(bundle: Bundle = .main,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> IPhoneDevAutoApprove? {
        #if DEBUG
        return IPhoneDevAutoApprove(build: BuildIdentity(bundle: bundle), environment: environment, debugBuild: true)
        #else
        return nil
        #endif
    }

    /// Whether `request` is a phone (never a machine) whose app is this tag's dev iPhone app.
    public func matches(_ request: MobileHostPairRequest) -> Bool {
        Self.phoneTag(of: request) == tag
    }
}
