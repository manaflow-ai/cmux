public import Foundation

// What a confirmation names for a pinned prompt or permission change (cx-zk9t).
extension BrowserPrompt {
    /// The prompt bar's own question for a permission request ("example.com wants to
    /// use your camera"); nil for a JavaScript dialog or credentials.
    public var permissionQuestion: String? {
        guard case .permission(let kind) = kind else { return nil }
        return switch kind {
        case .camera: Strings.permissionCamera(origin)
        case .microphone: Strings.permissionMicrophone(origin)
        case .cameraAndMicrophone: Strings.permissionCameraAndMicrophone(origin)
        case .automaticDownloads: Strings.permissionAutomaticDownloads(origin)
        }
    }
}

extension SitePermissionKind {
    /// The permission's localized name (Page Info's row title).
    public var displayName: String { PageInfoStrings.name(self) }
}
