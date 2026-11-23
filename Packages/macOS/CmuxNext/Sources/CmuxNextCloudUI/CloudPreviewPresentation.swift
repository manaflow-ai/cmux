public import CmuxNextActions
public import CmuxNextCloud
public import CmuxNextDesign
import Foundation

/// Shared presentation for the Cloud preview inventory used by native port actions.
@MainActor
public struct CloudPreviewPresentation {
    public let inventory: CloudMachinePreviews
    public let text: String
    public let copyable: Bool
    public let fields: [String: ActionResultValue]

    public init(_ inventory: CloudMachinePreviews) {
        self.inventory = inventory
        let lines = inventory.previews.map { "\($0.port) → \($0.url)" }
        text = lines.isEmpty ? CloudPortStrings.noPreviews : lines.joined(separator: "\n")
        copyable = !lines.isEmpty
        fields = [
            "machine_id": .string(inventory.machine),
            "ports": .string(inventory.listening.map(String.init).joined(separator: ",")),
            "listening": .array(inventory.listening.map(ActionResultValue.int)),
            "previews": .array(inventory.previews.map { .object([
                "port": .int($0.port), "url": .string($0.url), "origin": .string($0.origin), "expiresAt": .double($0.expiresAt),
            ]) }),
            "unavailable": .array(inventory.unavailable.map { .object(["port": .int($0.port), "code": .string($0.code)]) }),
        ]
    }

    public func picker(machineName: String, cancelTitle: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: CloudPortStrings.title, lines: [machineName], fields: [
            .choice(id: "port", label: nil,
                    options: inventory.previews.map { CmuxDialogOption(label: "\($0.port) · \($0.origin)", value: String($0.port)) },
                    selected: inventory.previews.first.map { String($0.port) }),
        ], buttons: [.cancel(cancelTitle), CmuxDialogButton(id: "open", title: CloudPortStrings.openPreview, role: .default)],
        identifier: "cmux.dialog.cloud.livePreviews")
    }

}
