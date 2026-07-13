import CmuxMobileShell
import CmuxMobileSupport
import Foundation

struct MobileMacUpdateFeatureDisplay {
    static func name(for feature: MobileMacUpdateFeature) -> String {
        switch feature {
        case .workspaceActions:
            L10n.string("mobile.macUpdateHint.feature.workspaceActions", defaultValue: "Rename and pin workspaces")
        case .workspaceReadState:
            L10n.string("mobile.macUpdateHint.feature.workspaceReadState", defaultValue: "Mark workspaces read or unread")
        case .workspaceClose:
            L10n.string("mobile.macUpdateHint.feature.workspaceClose", defaultValue: "Close workspaces")
        case .workspaceGroups:
            L10n.string("mobile.macUpdateHint.feature.workspaceGroups", defaultValue: "Workspace groups")
        case .workspaceMove:
            L10n.string("mobile.macUpdateHint.feature.workspaceMove", defaultValue: "Reorder workspaces")
        case .workspaceGroupActions:
            L10n.string("mobile.macUpdateHint.feature.workspaceGroupActions", defaultValue: "Move and group workspaces")
        case .workspaceCreateInGroup:
            L10n.string("mobile.macUpdateHint.feature.workspaceCreateInGroup", defaultValue: "Create workspaces inside groups")
        case .workspaceGroupCreate:
            L10n.string("mobile.macUpdateHint.feature.workspaceGroupCreate", defaultValue: "Create workspace groups")
        }
    }

    static func bodyText(hint: MobileMacUpdateHint, macName: String?) -> String {
        let displayName = macName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let displayName, !displayName.isEmpty {
            resolvedName = displayName
        } else {
            resolvedName = L10n.string("mobile.macUpdateHint.genericMacName", defaultValue: "Your Mac")
        }
        let featureList = ListFormatter.localizedString(
            byJoining: hint.features.map(MobileMacUpdateFeatureDisplay.name(for:))
        )
        // An inferred version proves the Mac is old enough to lack the
        // features, but stating it as the Mac's current version could be
        // wrong, so that variant only names the target version.
        if hint.isVersionInferred {
            let format = L10n.string(
                "mobile.macUpdateHint.bodyFormatUnknownVersion",
                defaultValue: "Updating %1$@ to cmux %2$@ or later adds: %3$@."
            )
            return String(
                format: format,
                resolvedName,
                hint.minimumMacVersion.description,
                featureList
            )
        }
        let format = L10n.string(
            "mobile.macUpdateHint.bodyFormat",
            defaultValue: "%1$@ is on cmux %2$@. Updating to %3$@ or later adds: %4$@."
        )
        return String(
            format: format,
            resolvedName,
            hint.macAppVersion.description,
            hint.minimumMacVersion.description,
            featureList
        )
    }
}
