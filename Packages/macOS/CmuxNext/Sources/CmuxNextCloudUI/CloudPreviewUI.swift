public import CmuxNextCloud
public import CmuxNextDesign
public import Foundation

/// Native preview dialogs; the host forwards network and browser operations.
@MainActor
public enum CloudPreviewUI {
    public static func present(_ inventory: CloudMachinePreviews, machineName: String,
                               present: (CmuxDialogSpec) async -> CmuxDialogAnswer,
                               share: (Int, String, String?) async throws -> String,
                               open: (CloudMachinePreview) async throws -> Void,
                               refreshOpen: (Int) async throws -> Void,
                               show: (String, String) -> Void, copy: (String) -> Void) async throws {
        guard !inventory.previews.isEmpty else {
            show(CloudPortStrings.title, CloudPortStrings.noPreviews)
            return
        }
        let choice = await present(previewPicker(inventory, machineName: machineName))
        guard !choice.isDismissal, let port = choice.text("port").flatMap(Int.init),
              let preview = inventory.previews.first(where: { $0.port == port }) else { return }
        if choice.button == "share" {
            let answer = await present(sharePicker(machineName: machineName))
            guard !answer.isDismissal, answer.button == "share", let audience = answer.text("audience") else { return }
            let user = audience == "user" ? answer.text("user_id").flatMap({ $0.isEmpty ? nil : $0 }) : nil
            let url = try await share(port, audience, user)
            copy(url)
            show(CloudPortStrings.shareTitle, url)
        } else if choice.button == "open" {
            if preview.expiresAt <= Date().timeIntervalSince1970 * 1000 {
                try await refreshOpen(port)
            } else {
                try await open(preview)
            }
        }
    }

    public static func previewPicker(_ inventory: CloudMachinePreviews, machineName: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: CloudPortStrings.title, lines: [machineName], fields: [
            .choice(id: "port", label: nil,
                    options: inventory.previews.map { CmuxDialogOption(label: "\($0.port) · \($0.origin)", value: String($0.port)) },
                    selected: inventory.previews.first.map { String($0.port) }),
        ], buttons: [.cancel(), CmuxDialogButton(id: "share", title: CloudPortStrings.share, role: .normal), CmuxDialogButton(id: "open", title: CloudPortStrings.openPreview, role: .default)],
        identifier: "cmux.dialog.cloud.livePreviews")
    }

    public static func sharePicker(machineName: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: CloudPortStrings.shareTitle, lines: [machineName, CloudPortStrings.shareDescription], fields: [
            .choice(id: "audience", label: nil, options: [
                CmuxDialogOption(label: CloudPortStrings.shareLink, value: "link"),
                CmuxDialogOption(label: CloudPortStrings.shareTeam, value: "team"),
                CmuxDialogOption(label: CloudPortStrings.sharePerson, value: "user"),
            ], selected: "link"),
            .text(id: "user_id", label: CloudPortStrings.sharePersonID, initial: "", placeholder: CloudPortStrings.sharePersonIDPlaceholder, secure: false),
        ], buttons: [.cancel(), CmuxDialogButton(id: "share", title: CloudPortStrings.share, role: .default)],
        identifier: "cmux.dialog.cloud.sharePreview")
    }

}
