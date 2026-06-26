public import AuthenticationServices

extension ASAuthorizationPublicKeyCredentialAttachment {
    /// The browser-facing `authenticatorAttachment` string for this attachment.
    public var browserAttachmentValue: String {
        switch self {
        case .platform:
            return "platform"
        case .crossPlatform:
            return "cross-platform"
        @unknown default:
            return "cross-platform"
        }
    }
}
