/// The native browser interaction represented by a mobile dialog.
public enum MobileBrowserDialogKind: String, Codable, Equatable, Sendable {
    /// cmux's warning before navigating to an insecure HTTP URL.
    case insecureHTTP = "insecure_http"
    /// A JavaScript `alert()` request.
    case javaScriptAlert = "javascript_alert"
    /// A JavaScript `confirm()` request.
    case javaScriptConfirm = "javascript_confirm"
    /// A JavaScript `prompt()` request.
    case javaScriptPrompt = "javascript_prompt"
    /// An HTTP Basic authentication challenge.
    case httpBasicAuthentication = "http_basic_authentication"
    /// A WebKit media-capture permission prompt.
    case mediaCapturePermission = "media_capture_permission"
    /// A file-upload picker that must be completed on the Mac.
    case fileUpload = "file_upload"
    /// A client-certificate picker that must be completed on the Mac.
    case clientCertificate = "client_certificate"
}
