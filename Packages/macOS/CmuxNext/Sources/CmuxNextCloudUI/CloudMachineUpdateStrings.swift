import Foundation

/// Update Machine's text (the App's `CloudMachineUpdate`, and the automatic update's reasons,
/// `CloudMachineUpdateTarget`). Keys live in Resources/Cloud.xcstrings with every app locale.
public nonisolated enum CloudMachineUpdateStrings {
    /// The button on a `machine_outdated` stop's toast.
    public static var button: String {
        String(localized: "cloud.machineUpdate.button", defaultValue: "Update Machine", table: "Cloud", bundle: .module)
    }
    public static func updating(_ machine: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.updating", defaultValue: "Updating cmux on %@…", table: "Cloud", bundle: .module), machine)
    }
    /// A machine too old to update in place: what still works there, never "use another machine".
    public static func unsupported(_ machine: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.unsupportedKeepsWorking",
                              defaultValue: "%@ runs a cmux too old to update in place. Its chats and terminals keep working; features newer than its cmux stay off there.",
                              table: "Cloud", bundle: .module), machine)
    }
    public static func unavailable(_ machine: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.unavailable", defaultValue: "This build of cmux can't update %@. A release build can.",
                              table: "Cloud", bundle: .module), machine)
    }
    public static func failed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.failed", defaultValue: "Couldn't update cmux on %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
}
