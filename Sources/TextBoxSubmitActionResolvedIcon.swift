import AppKit
import CmuxAppKitSupportUI

extension TextBoxInputContainer {
    func resolvedSubmitActionAssetName(for action: TextBoxSubmitAction) -> String? {
        guard let assetName = action.assetName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !assetName.isEmpty else { return nil }
        return assetName
    }

    func submitActionIconRequest(assetName: String) -> CmuxResolvedIconRequest {
        CmuxResolvedIconRequest(
            source: .asset(name: assetName, bundle: .main),
            size: NSSize(
                width: TextBoxSubmitActionImageSupport.iconSize,
                height: TextBoxSubmitActionImageSupport.iconSize
            )
        )
    }
}
