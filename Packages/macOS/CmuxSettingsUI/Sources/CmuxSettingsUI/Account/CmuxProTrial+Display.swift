import CMUXMobileCore
import Foundation

/// The copy every macOS surface uses to name a Pro free trial, so the Settings
/// account row, the Cloud plan row, the sidebar and the pricing window agree.
public extension CmuxProTrial {
    /// The plan name: "Pro trial", never the Go allowance the trial runs on.
    static var displayName: String {
        String(localized: "plan.proTrial.name", defaultValue: "Pro trial", bundle: .module)
    }

    /// What the trial includes, from the service's numbers: "1 machine with
    /// 2 vCPU and 4 GB RAM, and 20 VM-hours". When any number is missing, the
    /// standard trial allowance is stated instead.
    var allowanceText: String {
        guard let machines = limits.machines, let vcpus = limits.vcpus,
              let memoryGb = limits.memoryGb, let vmHours = limits.vmHours else {
            return String(
                localized: "plan.proTrial.allowance",
                defaultValue: "1 machine with 2 vCPU and 4 GB RAM, and 20 VM-hours",
                bundle: .module
            )
        }
        let machinesText = String(
            format: String(localized: "plan.proTrial.machines", defaultValue: "%d machines", bundle: .module),
            machines
        )
        let sizeText = String(
            format: String(localized: "plan.proTrial.size", defaultValue: "%1$@ vCPU and %2$@ GB RAM", bundle: .module),
            vcpus.formatted(),
            memoryGb.formatted()
        )
        let hoursText = String(
            format: String(localized: "plan.proTrial.vmHours", defaultValue: "%d VM-hours", bundle: .module),
            vmHours
        )
        return String(
            format: String(localized: "plan.proTrial.allowanceFormat", defaultValue: "%1$@ with %2$@, and %3$@", bundle: .module),
            machinesText,
            sizeText,
            hoursText
        )
    }

    /// "Pro trial: 1 machine with 2 vCPU and 4 GB RAM, and 20 VM-hours. Ends Oct 22, 2026."
    /// The end date is left out when the Cloud service did not send it.
    var summaryText: String {
        guard let endsAt else {
            return String(
                format: String(localized: "plan.proTrial.summary", defaultValue: "Pro trial: %@.", bundle: .module),
                allowanceText
            )
        }
        return String(
            format: String(localized: "plan.proTrial.summaryEnds", defaultValue: "Pro trial: %1$@. Ends %2$@.", bundle: .module),
            allowanceText,
            endsAt.formatted(date: .abbreviated, time: .omitted)
        )
    }

    /// "1 machine with 2 vCPU and 4 GB RAM, and 20 VM-hours. Ends Oct 22, 2026."
    /// for a surface whose title already names the trial.
    var detailText: String {
        guard let endsAt else { return allowanceText }
        return String(
            format: String(localized: "plan.proTrial.detailEnds", defaultValue: "%1$@. Ends %2$@.", bundle: .module),
            allowanceText,
            endsAt.formatted(date: .abbreviated, time: .omitted)
        )
    }
}
