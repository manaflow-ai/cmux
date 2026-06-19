import CmuxControlSocket
import CmuxSettings
import CmuxSwiftRenderUI
import Foundation

/// App-side seam for the worker-lane `sidebar.custom.*` socket commands.
extension TerminalController {
    nonisolated func v2CustomSidebarValidate(params: [String: JSONValue]) -> ControlCallResult {
        customSidebarCommandHandler.validate(
            params: params,
            directory: CmuxExtensionSidebarSelection.customSidebarsDirectory,
            messages: customSidebarCommandMessages
        )
    }

    nonisolated func v2CustomSidebarReload(params: [String: JSONValue]) -> ControlCallResult {
        customSidebarCommandHandler.reload(
            params: params,
            directory: CmuxExtensionSidebarSelection.customSidebarsDirectory,
            messages: customSidebarCommandMessages
        ) { [self] names in
            v2MainSync {
                NotificationCenter.default.post(
                    name: .customSidebarReloadRequested,
                    object: nil,
                    userInfo: ["names": names]
                )
            }
        }
    }

    nonisolated func v2CustomSidebarSelect(params: [String: JSONValue]) -> ControlCallResult {
        customSidebarCommandHandler.select(
            params: params,
            directory: CmuxExtensionSidebarSelection.customSidebarsDirectory,
            providerIDPrefix: CmuxExtensionSidebarSelection.customSidebarProviderPrefix,
            messages: customSidebarCommandMessages
        ) { [self] selection in
            v2MainSync {
                UserDefaults.standard.set(true, forKey: SettingCatalog().betaFeatures.customSidebars.userDefaultsKey)
                CmuxExtensionSidebarSelection.setProviderId(selection.providerID)
                NotificationCenter.default.post(
                    name: .customSidebarReloadRequested,
                    object: nil,
                    userInfo: ["names": [selection.name]]
                )
            }
        }
    }

    private nonisolated var customSidebarCommandMessages: ControlCustomSidebarCommandMessages {
        ControlCustomSidebarCommandMessages(
            invalidName: String(
                localized: "socket.sidebar.custom.invalidName",
                defaultValue: "Sidebar name must not be empty."
            ),
            selectMissingName: String(
                localized: "socket.sidebar.custom.selectMissingName",
                defaultValue: "Select requires a sidebar name."
            )
        )
    }
}
