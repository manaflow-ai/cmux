import Foundation

/// What Share with Me says (CloudMachineShare.swift). Keys live in Resources/CloudShare.xcstrings
/// with every app locale.
enum CloudShareStrings {
    static var notCloudMachine: String { String(localized: "cloud.share.notCloudMachine", defaultValue: "This chat's machine is not a cmux Cloud machine, so it has nothing to share.", table: "CloudShare", bundle: .module) }
}
