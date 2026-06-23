import Foundation
import CmuxMobileShellModel

extension MacComputerSnapshot {
    /// Returns whether this computer should remain visible for a Computers-screen
    /// search query. Keep this value-only so the list rows stay below the
    /// snapshot boundary without reaching back into the shell store.
    func matchesSearchQuery(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        return searchableTextFields.contains { field in
            field.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchableTextFields: [String] {
        [
            title,
            deviceId,
            platform,
            customColor,
            customIcon,
            buildLabel,
            routeDescription,
            connectionStatus?.searchToken,
            presence?.searchToken,
        ].compactMap { $0 }
    }
}

private extension MobileMacConnectionStatus {
    var searchToken: String {
        switch self {
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .unavailable:
            return "unavailable"
        }
    }
}

private extension DeviceTreePresence {
    var searchToken: String {
        switch self {
        case .online:
            return "online"
        case .offline:
            return "offline"
        }
    }
}
