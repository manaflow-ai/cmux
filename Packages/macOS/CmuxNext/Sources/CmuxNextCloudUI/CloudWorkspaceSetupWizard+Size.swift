public import CmuxNextCloud
import CmuxNextDesign
public import Foundation

// The machine size in New Cloud Workspace: the plan's sizes from `GET /api/vm`'s `limits`
// (`memoryOptionsMb`, `vcpusByMemoryMb`) and, where the server already priced a machine of that
// size, its hourly rate (`hourlyRateUsd`). The app keeps no size or rate table of its own: a size
// the server gave no vCPUs for shows its memory only, and a size no listed machine has shows no rate.
extension CloudWorkspaceSetupWizard {
    /// One size the plan offers.
    public nonisolated struct SizeOption: Sendable, Equatable {
        public var memoryMb: Int
        public var vcpus: Int?
        /// The server's hourly rate for a machine of this size, when one it listed has the same size.
        public var hourlyRateUsd: Double?

        public init(memoryMb: Int, vcpus: Int? = nil, hourlyRateUsd: Double? = nil) {
            self.memoryMb = memoryMb
            self.vcpus = vcpus
            self.hourlyRateUsd = hourlyRateUsd
        }

        /// "2 vCPU, 4 GB memory · $0.13/h", or less when the server sent less.
        public func label(locale: Locale = .current) -> String {
            let memoryGB = Self.gigabytes(memoryMb, locale: locale)
            let size = vcpus.map { CloudWorkspaceSetupWizardSizeStrings.size(vcpus: $0.formatted(.number.locale(locale)), memoryGB: memoryGB) }
                ?? CloudWorkspaceSetupWizardSizeStrings.memoryOnly(memoryGB)
            guard let rate = hourlyRateUsd else { return size }
            return CloudWorkspaceSetupWizardSizeStrings.withRate(size, rate: Self.price(rate, locale: locale))
        }

        /// The dialog's choice value for this size.
        var value: String { String(memoryMb) }

        /// 4096 MB as "4", 1536 MB as "1.5".
        static func gigabytes(_ mb: Int, locale: Locale) -> String {
            (Double(mb) / 1024).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        }

        /// US dollars to the cent ("$0.13"), as the sidebar's machine cost shows them.
        static func price(_ usd: Double, locale: Locale) -> String {
            usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
        }

        /// The plan's sizes, smallest first. A size's rate comes from the listed machines of exactly
        /// that size (vCPUs and memory) whose rates agree; machines of another provider or price leave it out.
        public static func options(limits: CloudMachineLimits?, machines: [CloudMachine]) -> [SizeOption] {
            guard let limits else { return [] }
            return limits.memoryOptionsMb.map { mb in
                let vcpus = limits.vcpusByMemoryMb[mb]
                let rates = Set(machines.compactMap { machine -> Double? in
                    guard let size = machine.size, size.memoryMb == mb, let vcpus, size.cpu == vcpus else { return nil }
                    return machine.hourlyRateUsd
                })
                return SizeOption(memoryMb: mb, vcpus: vcpus, hourlyRateUsd: rates.count == 1 ? rates.first : nil)
            }
        }
    }

    /// The dialog's size choice: the plan's sizes, the smallest selected. `autosized`: the chat the
    /// setup was asked from sizes its own repository's machine, offered first and selected.
    nonisolated static func sizeField(_ sizes: [SizeOption], autosized: Bool) -> CmuxDialogField? {
        guard !sizes.isEmpty else { return nil }
        var options = sizes.map { CmuxDialogOption(label: $0.label(), value: $0.value) }
        if autosized { options.insert(CmuxDialogOption(label: CloudWorkspaceSetupWizardSizeStrings.automatic, value: automaticSize), at: 0) }
        return .choice(id: sizeFieldID, label: CloudWorkspaceSetupWizardSizeStrings.label, options: options, selected: options.first?.value)
    }

    /// The answer's size: nil keeps the plan's default (or the chat's own sizing); a value no
    /// offered size names is nil too, so a stale answer never asks for a size the plan refused.
    nonisolated static func memoryMb(answer: String?, sizes: [SizeOption]) -> Int? {
        guard let answer, answer != automaticSize, let mb = Int(answer) else { return nil }
        return sizes.contains { $0.memoryMb == mb } ? mb : nil
    }

    nonisolated static let sizeFieldID = "size"
    nonisolated static let automaticSize = "auto"
}

enum CloudWorkspaceSetupWizardSizeStrings {
    nonisolated static let label = String(localized: "cloud.workspaceSetup.sizeLabel", defaultValue: "Machine size", table: "Cloud", bundle: .module)
    nonisolated static let automatic = String(localized: "cloud.workspaceSetup.sizeAutomatic", defaultValue: "Automatic (sized for the chat's repository)", table: "Cloud", bundle: .module)
    /// vCPU is a unit with no plural form, so the count is a formatted number, not a plural.
    nonisolated static func size(vcpus: String, memoryGB: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.size", defaultValue: "%1$@ vCPU, %2$@ GB memory", table: "Cloud", bundle: .module), vcpus, memoryGB)
    }
    nonisolated static func memoryOnly(_ memoryGB: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.sizeMemory", defaultValue: "%@ GB memory", table: "Cloud", bundle: .module), memoryGB)
    }
    /// The size and its hourly rate: "2 vCPU, 4 GB memory · $0.13/h".
    nonisolated static func withRate(_ size: String, rate: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.sizeRate", defaultValue: "%1$@ · %2$@/h", table: "Cloud", bundle: .module), size, rate)
    }
}
