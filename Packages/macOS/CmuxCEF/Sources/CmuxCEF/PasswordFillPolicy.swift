/// The one policy for Chromium password filling in a CEF page.
///
/// Automated pages never fill saved credentials. A person-facing page fills
/// only when its profile has password filling enabled. This keeps autofill
/// suggestion clicks useful for people while preventing an automation click
/// from releasing a secret to page script.
public nonisolated struct PasswordFillPolicy: Sendable {
    public init() {}

    /// Returns whether Chromium may offer or fill a saved password.
    public static func fills(agentDriven: Bool, profileAllows: Bool) -> Bool {
        !agentDriven && profileAllows
    }
}

/// Tracks the last per-tab fill switch sent to Chromium.
public nonisolated struct PasswordFillState: Sendable, Equatable {
    public private(set) var allowedByProfile = true
    /// The value most recently sent to Chromium. `nil` means the browser has
    /// not been created yet and must receive an explicit initial policy.
    private var lastSentValue: Bool?

    public init() {}

    public func fills(agentDriven: Bool) -> Bool {
        PasswordFillPolicy.fills(agentDriven: agentDriven, profileAllows: allowedByProfile)
    }

    /// Updates the profile policy and reports whether it changed.
    @discardableResult
    public mutating func setAllowedByProfile(_ allowed: Bool) -> Bool {
        defer { allowedByProfile = allowed }
        return allowed != allowedByProfile
    }

    /// Whether Chromium was last told to fill: a live page may then hold a
    /// password it filled.
    public var sentFillOn: Bool { lastSentValue == true }

    /// The page got a new Chromium browser (Memory Saver, a reopen), which
    /// starts with Chromium's default: the next switch value is sent again.
    public mutating func browserRecreated() {
        lastSentValue = nil
    }

    /// Returns the CEF switch value only when Chromium needs a transition.
    public mutating func nextSwitchValue(agentDriven: Bool) -> Int32? {
        let shouldFill = fills(agentDriven: agentDriven)
        guard lastSentValue != shouldFill else { return nil }
        lastSentValue = shouldFill
        return shouldFill ? 1 : 0
    }
}
