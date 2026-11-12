import Foundation

/// The plan picker's text (``CloudPlanPicker``), in Resources/Cloud.xcstrings with every app locale. Plan names are
/// product names and stay as they are in every language.
struct CloudPlanPickerStrings {
    static func name(_ plan: CloudPlanPicker.PlanID) -> String {
        switch plan {
        case .pro: "Pro"
        case .max: "Max"
        case .team: "Team"
        }
    }

    static var title: String {
        String(localized: "cloud.planPicker.title", defaultValue: "Choose a plan for Cloud", table: "Cloud", bundle: .module)
    }
    static var subtitle: String {
        String(localized: "cloud.planPicker.subtitle", defaultValue: "Cloud workspaces run on cmux machines and need a paid plan. Everything on this Mac stays free.",
               table: "Cloud", bundle: .module)
    }
    static var subtitleMax: String {
        String(localized: "cloud.planPicker.subtitleMax", defaultValue: "This machine needs Max: larger machines and a bigger shared pool. Everything on this Mac stays free.",
               table: "Cloud", bundle: .module)
    }
    static var monthly: String { String(localized: "cloud.planPicker.monthly", defaultValue: "Monthly", table: "Cloud", bundle: .module) }
    static var annual: String { String(localized: "cloud.planPicker.annual", defaultValue: "Annual", table: "Cloud", bundle: .module) }
    static func save(_ percent: Int) -> String {
        String(format: String(localized: "cloud.planPicker.save", defaultValue: "Save %d%%", table: "Cloud", bundle: .module), percent)
    }
    static var recommended: String { String(localized: "cloud.planPicker.recommended", defaultValue: "Recommended", table: "Cloud", bundle: .module) }
    static var perMonth: String { String(localized: "cloud.planPicker.perMonth", defaultValue: "/mo", table: "Cloud", bundle: .module) }
    static var perSeatMonth: String { String(localized: "cloud.planPicker.perSeatMonth", defaultValue: "/seat/mo", table: "Cloud", bundle: .module) }
    static var billedMonthly: String { String(localized: "cloud.planPicker.billedMonthly", defaultValue: "Billed monthly", table: "Cloud", bundle: .module) }
    static func billedYearly(_ price: String) -> String {
        String(format: String(localized: "cloud.planPicker.billedYearly", defaultValue: "Billed %@ yearly", table: "Cloud", bundle: .module), price)
    }
    static func included(_ price: String, perSeat: Bool) -> String {
        perSeat
            ? String(format: String(localized: "cloud.planPicker.includedSeat", defaultValue: "%@ of usage included per seat each month", table: "Cloud", bundle: .module), price)
            : String(format: String(localized: "cloud.planPicker.included", defaultValue: "%@ of usage included each month", table: "Cloud", bundle: .module), price)
    }
    static func choose(_ plan: CloudPlanPicker.PlanID) -> String {
        String(format: String(localized: "cloud.planPicker.choose", defaultValue: "Get %@", table: "Cloud", bundle: .module), name(plan))
    }
    static func today(_ price: String) -> String {
        String(format: String(localized: "cloud.planPicker.today", defaultValue: "Today: %@", table: "Cloud", bundle: .module), price)
    }
    static func machineSize(cpu: Int, memoryGB: Int) -> String {
        String(format: String(localized: "cloud.planPicker.machineSize", defaultValue: "Machine size: up to %1$d vCPU, %2$d GB RAM", table: "Cloud", bundle: .module), cpu, memoryGB)
    }
    static func pool(cpu: Int, memoryGB: Int, perSeat: Bool) -> String {
        perSeat
            ? String(format: String(localized: "cloud.planPicker.poolSeat", defaultValue: "Shared per seat: %1$d vCPU, %2$d GB RAM", table: "Cloud", bundle: .module), cpu, memoryGB)
            : String(format: String(localized: "cloud.planPicker.pool", defaultValue: "Shared across machines: %1$d vCPU, %2$d GB RAM", table: "Cloud", bundle: .module), cpu, memoryGB)
    }
    static func machines(_ count: Int, perSeat: Bool) -> String {
        perSeat
            ? String(format: String(localized: "cloud.planPicker.machinesSeat", defaultValue: "Running machines per seat: %d", table: "Cloud", bundle: .module), count)
            : String(format: String(localized: "cloud.planPicker.machines", defaultValue: "Running machines: %d", table: "Cloud", bundle: .module), count)
    }
    static func storage(_ gb: Int) -> String {
        String(format: String(localized: "cloud.planPicker.storage", defaultValue: "Storage: up to %d GB per machine", table: "Cloud", bundle: .module), gb)
    }
}
