import CMUXMobileCore
import Foundation

/// The copy every macOS surface uses to name a Pro free trial, so the Settings
/// account row, the Cloud plan row, the sidebar and the pricing window agree.
public extension CmuxProTrial {
    /// The plan name: "Pro trial", never the Go allowance the trial runs on.
    static var displayName: String {
        String(localized: "plan.proTrial.name", defaultValue: "Pro trial", bundle: .module)
    }

    /// What the trial includes. The allowance is fixed by the Cloud service
    /// (one machine of 2 vCPU and 4 GB, 20 VM-hours) and enforced there.
    static var allowanceText: String {
        String(
            localized: "plan.proTrial.allowance",
            defaultValue: "1 machine with 2 vCPU and 4 GB RAM, and 20 VM-hours",
            bundle: .module
        )
    }

    /// "Pro trial: 1 machine with 2 vCPU and 4 GB RAM, and 20 VM-hours. Ends Oct 22, 2026."
    /// The end date is left out when the Cloud service did not send it.
    var summaryText: String {
        guard let endsAt else {
            return String(
                format: String(localized: "plan.proTrial.summary", defaultValue: "Pro trial: %@.", bundle: .module),
                Self.allowanceText
            )
        }
        return String(
            format: String(localized: "plan.proTrial.summaryEnds", defaultValue: "Pro trial: %1$@. Ends %2$@.", bundle: .module),
            Self.allowanceText,
            endsAt.formatted(date: .abbreviated, time: .omitted)
        )
    }

    /// "1 machine with 2 vCPU and 4 GB RAM, and 20 VM-hours. Ends Oct 22, 2026."
    /// for a surface whose title already names the trial.
    var detailText: String {
        guard let endsAt else { return Self.allowanceText }
        return String(
            format: String(localized: "plan.proTrial.detailEnds", defaultValue: "%1$@. Ends %2$@.", bundle: .module),
            Self.allowanceText,
            endsAt.formatted(date: .abbreviated, time: .omitted)
        )
    }
}
