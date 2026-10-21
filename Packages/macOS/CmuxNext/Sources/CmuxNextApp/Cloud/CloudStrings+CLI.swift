import Foundation

/// What a CLI or agent run of a Cloud action hears back. Keys live in
/// Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    /// `cloud new-machine` from a CLI or agent: the person said no in the confirmation, or
    /// dismissed the creation, so no machine was made.
    static var createDeclined: String {
        String(localized: "cloud.cli.createDeclined", defaultValue: "No Cloud machine was created: the person declined or dismissed it in cmux.",
               table: "Cloud", bundle: .module)
    }
}
