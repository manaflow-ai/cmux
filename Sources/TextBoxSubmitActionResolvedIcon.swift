import AppKit
import CmuxAppKitSupportUI

extension TextBoxInputContainer {
    func resolvedSubmitActionAssetName(for action: TextBoxSubmitAction) -> String? {
        if let path = action.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return nil
        }
        guard let assetName = action.assetName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !assetName.isEmpty else {
            return nil
        }
        guard submitActionAssetAvailabilityCache[submitActionAssetImageCacheKey(assetName)] == true else {
            return nil
        }
        return assetName
    }

    func submitActionIconRequest(assetName: String, tintColor: NSColor? = nil) -> CmuxResolvedIconRequest {
        CmuxResolvedIconRequest(
            source: .asset(name: assetName, bundle: .main),
            size: NSSize(
                width: TextBoxSubmitActionImageSupport.iconSize,
                height: TextBoxSubmitActionImageSupport.iconSize
            ),
            tintColor: tintColor
        )
    }
}
