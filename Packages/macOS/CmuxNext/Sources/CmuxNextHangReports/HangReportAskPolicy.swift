/// What NIGHTLY does about hang reports on this Mac, from the setting, this Mac's own consent
/// record and the anonymous telemetry choice.
///
/// `diagnostics.hangReports` lives in cmux-next.json, which people sync between Macs and agents
/// can edit, so the file alone never starts sending: this Mac must also hold a consent record
/// that only the person's own yes writes (the card's Send Hang Reports, or a `SettingWriter.user`
/// write of the setting: the Settings switch, Toggle Setting, a CLI call the confirmation sheet
/// approved). A file that turns reports on without a record shows the confirm card instead. A
/// person who turned off anonymous telemetry is never invited (lead decision 2026-10-23), but can
/// still turn reports on in Settings.
///
/// ```swift
/// HangReportAskPolicy().decision(settingOn: true, consented: false, invited: true, telemetryOptIn: false)  // .confirm
/// ```
public nonisolated struct HangReportAskPolicy: Sendable {
    /// What to do.
    public enum Decision: Sendable, Hashable {
        /// Reports on: record and send.
        case send
        /// The setting is on but this Mac never confirmed: show the confirm card, send nothing yet.
        case confirm
        /// Reports off and never asked: show the one-time invitation card.
        case invite
        /// Reports off: send nothing, ask nothing.
        case off
    }

    /// Makes the policy.
    public init() {}

    /// - Parameters:
    ///   - settingOn: `diagnostics.hangReports` is on in the file.
    ///   - consented: This Mac holds the person's consent record.
    ///   - invited: The one-time invitation was shown before on this Mac (any answer).
    ///   - telemetryOptIn: The anonymous telemetry choice (on until the person turns it off).
    /// - Returns: What to do now.
    public func decision(settingOn: Bool, consented: Bool, invited: Bool, telemetryOptIn: Bool) -> Decision {
        if settingOn { return consented ? .send : .confirm }
        return !invited && telemetryOptIn ? .invite : .off
    }
}
