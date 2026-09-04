import CmuxMobileShell
import CmuxMobileSupport
import Foundation

struct MacAppInstanceDisplayFormatter {
    func localizedBuildLabel(_ label: String) -> String {
        let taggedDevPrefix = "DEV · "
        if label.hasPrefix(taggedDevPrefix) {
            let format = L10n.string(
                "mobile.computers.build.devTaggedFormat",
                defaultValue: "DEV · %@"
            )
            return String(format: format, String(label.dropFirst(taggedDevPrefix.count)))
        }
        switch label {
        case "Stable":
            return L10n.string("mobile.computers.build.stable", defaultValue: "Stable")
        case "Nightly":
            return L10n.string("mobile.computers.build.nightly", defaultValue: "Nightly")
        case "RC":
            return L10n.string("mobile.computers.build.rc", defaultValue: "RC")
        case "Staging":
            return L10n.string("mobile.computers.build.staging", defaultValue: "Staging")
        case "DEV":
            return L10n.string("mobile.computers.build.dev", defaultValue: "DEV")
        default:
            return label
        }
    }

    func displayName(_ displayName: String, instanceTag: String?) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? L10n.string("mobile.iroh.private.custom.unnamedMac", defaultValue: "Mac")
            : trimmed
        guard let label = MacBuildChannel().label(bundleID: nil, tag: instanceTag) else {
            return name
        }
        let format = L10n.string(
            "mobile.workspaces.macPicker.titleWithBuildFormat",
            defaultValue: "%1$@ · %2$@"
        )
        return String(format: format, name, localizedBuildLabel(label))
    }
}
