public import CmuxNextCloud
import Foundation

/// Transfer to This Mac's text (the App's `CloudTransferLocal`). Keys live in Resources/Cloud.xcstrings
/// with every app locale.
public struct CloudTransferLocalStrings {
    public init() {}
    public static var copying: String {
        String(localized: "cloud.transferLocal.copying", defaultValue: "Copying the chat's folder to this Mac…", table: "Cloud", bundle: .module)
    }
    /// The folder under the home folder new transfers go to.
    public static var folderName: String {
        String(localized: "cloud.transferLocal.folderName", defaultValue: "Cloud Transfers", table: "Cloud", bundle: .module)
    }
    public static func copied(_ machine: String) -> String {
        String(format: String(localized: "cloud.transferLocal.copied",
                              defaultValue: "Your copy of the folder is open on this Mac. The chat keeps running on %@.",
                              table: "Cloud", bundle: .module), machine)
    }
    public static var notAMachineChat: String {
        String(localized: "cloud.transferLocal.notAMachineChat", defaultValue: "Transfer to This Mac works on a chat that runs on a Cloud machine.",
               table: "Cloud", bundle: .module)
    }
    public static var noFolder: String {
        String(localized: "cloud.transferLocal.noFolder", defaultValue: "This chat has no folder on the machine to copy.", table: "Cloud", bundle: .module)
    }
    public static var tooBroad: String {
        String(localized: "cloud.transferLocal.tooBroad", defaultValue: "This chat's folder on the machine is a home or top folder, which holds the machine's sign-ins. Open the chat in a project folder to transfer it.", table: "Cloud", bundle: .module)
    }
    public static func copyFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.transferLocal.copyFailed", defaultValue: "Couldn't copy the folder from %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
    public static func folderNotEmpty(_ folder: String) -> String {
        String(format: String(localized: "cloud.transferLocal.folderNotEmpty",
                              defaultValue: "%@ already has files. Pick a new or empty folder.", table: "Cloud", bundle: .module), folder)
    }
    public static var notOnRemote: String {
        String(localized: "cloud.transferLocal.notOnRemote",
               defaultValue: "The machine's branch isn't on its remote yet. Push it from the machine, then transfer again.",
               table: "Cloud", bundle: .module)
    }
    public static var cloneFailed: String {
        String(localized: "cloud.transferLocal.cloneFailed",
               defaultValue: "This Mac couldn't clone the project from its remote. Check that you can reach the repository, then try again.",
               table: "Cloud", bundle: .module)
    }
    public static func failed(_ detail: String) -> String {
        String(format: String(localized: "cloud.transferLocal.failed",
                              defaultValue: "Couldn't transfer the chat to this Mac. Try again; if it keeps failing, run `cmux cloud diagnostics`. Reason: %@",
                              table: "Cloud", bundle: .module), detail)
    }

    /// A `cmux link seed fetch` refusal, in plain words; nil for `sync_conflict`, whose text names the files.
    public static func refusal(_ answer: CloudMoveCLI.Answer, machine: String, folder: String) -> String? {
        switch answer.errorCode {
        case "fetch.folder_not_empty": return folderNotEmpty(folder)
        case "fetch.no_folder": return noFolder
        case "fetch.too_broad": return tooBroad
        case "fetch.base_unreachable": return notOnRemote
        case "fetch.clone_failed", "fetch.no_remote", "fetch.not_a_seed": return cloneFailed
        case "sync_conflict": return nil
        default: return copyFailed(machine, answer.error ?? answer.errorCode ?? "")
        }
    }
}
