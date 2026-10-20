public import Foundation

/// Runs email verification AutoFill. Stub: the red commit of its tests.
public final class VerificationAutofillCoordinator {
    public private(set) var lastSourceError: (any Error)?
    public init(inbox: VerificationInbox, source: any VerificationEmailSource, isEnabled: @escaping () -> Bool,
                now: @escaping () -> Date = Date.init, clock: any Clock<Duration> = ContinuousClock(),
                pollInterval: Duration = .seconds(3)) {}
    public func pageWaiting(_ tab: any BrowserTab) {}
    public func settingChanged() {}
    func pollOnce() async {}
    func settle() async {}
}
