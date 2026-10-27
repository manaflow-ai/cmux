/// What NIGHTLY does about hang reports on this Mac, from the setting, this Mac's own consent
/// record and the anonymous telemetry choice; and what any channel does about aggregate performance data
/// (``performanceDataDecision(settingOn:consented:)``, ``mode(hangReports:performanceData:fullReports:)``).
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

    /// The two settings the app follows: `diagnostics.hangReports` and `diagnostics.performanceData`.
    public struct Settings: Sendable, Hashable {
        /// `diagnostics.hangReports` is on in the file.
        public var hangReports: Bool
        /// `diagnostics.performanceData` is on in the file.
        public var performanceData: Bool

        /// Makes the value from its parts.
        public init(hangReports: Bool, performanceData: Bool) {
            self.hangReports = hangReports
            self.performanceData = performanceData
        }
    }

    /// A sidebar card the app puts up at most once per launch.
    public enum Card: Sendable, Hashable {
        /// Hang reports are on in the file but this Mac never confirmed them.
        case hangReportsConfirm
        /// Performance data is on in the file but this Mac never confirmed it.
        case performanceDataConfirm
        /// The one-time hang reports invitation.
        case hangReportsInvite

        /// Whether the card's yes turns on `diagnostics.performanceData` (else `diagnostics.hangReports`).
        public var isPerformanceData: Bool { self == .performanceDataConfirm }
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

    /// What any channel does about aggregate performance data (`diagnostics.performanceData`, default off): the same
    /// per-Mac consent rule, and never an invitation (only the person's own switch turns it on, as Chrome's
    /// "Help improve Chrome" is off until the person checks it).
    ///
    /// - Parameters:
    ///   - settingOn: `diagnostics.performanceData` is on in the file.
    ///   - consented: This Mac holds the person's consent record for performance data.
    /// - Returns: `.send`, `.confirm` or `.off`.
    public func performanceDataDecision(settingOn: Bool, consented: Bool) -> Decision {
        guard settingOn else { return .off }
        return consented ? .send : .confirm
    }

    /// The card the two decisions ask for: a confirm of what the person turned on before an unprompted invitation;
    /// nil when neither asks.
    public func card(hangReports: Decision, performanceData: Decision) -> Card? {
        if hangReports == .confirm { return .hangReportsConfirm }
        if performanceData == .confirm { return .performanceDataConfirm }
        return hangReports == .invite ? .hangReportsInvite : nil
    }

    /// What the service records and sends from both decisions: full hang reports where the build sends them
    /// (`fullReports`, NIGHTLY) and they are on, else the aggregates when performance data is on, else nothing.
    public func mode(hangReports: Decision, performanceData: Decision, fullReports: Bool) -> HangReportService.Mode {
        if fullReports, hangReports == .send { return .full }
        return performanceData == .send ? .aggregates : .off
    }
}
