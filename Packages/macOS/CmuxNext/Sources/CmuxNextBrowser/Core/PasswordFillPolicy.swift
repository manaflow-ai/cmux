/// The one rule for Chromium's saved-password filling in a tab
/// (plans/cmux-next/passwords.md, slice 1). An agent-driven tab never fills
/// (an automated click is a user gesture that would release a filled
/// password to page script); a tab whose profile does not allow it never
/// fills (an extension is the profile's password manager, or the person
/// turned autofill off); otherwise Chromium's default, fill. Every caller of
/// the fork's per-tab switch (`cmux_tab_set_password_fill`) goes through it.
public nonisolated enum PasswordFillPolicy {
    public static func fills(agentDriven: Bool, profileAllows: Bool) -> Bool {
        !agentDriven && profileAllows
    }
}

/// One tab's input to `PasswordFillPolicy` from its profile, and what the
/// tab last sent to Chromium's switch. Chromium fills by default, so a tab
/// that fills and was never turned off sends nothing.
nonisolated struct PasswordFillState {
    private(set) var allowedByProfile = true
    private var switchedOff = false

    func fills(agentDriven: Bool) -> Bool { PasswordFillPolicy.fills(agentDriven: agentDriven, profileAllows: allowedByProfile) }

    /// True when the value changed.
    mutating func setAllowedByProfile(_ allowed: Bool) -> Bool {
        defer { allowedByProfile = allowed }
        return allowed != allowedByProfile
    }

    /// The switch value to send now (1 fill, 0 do not), or nil when Chromium already has it.
    mutating func nextSwitchValue(agentDriven: Bool) -> Int32? {
        let fills = fills(agentDriven: agentDriven)
        // Send only a change: on while switched off, or off while still on.
        guard fills == switchedOff else { return nil }
        switchedOff = !fills
        return fills ? 1 : 0
    }
}
