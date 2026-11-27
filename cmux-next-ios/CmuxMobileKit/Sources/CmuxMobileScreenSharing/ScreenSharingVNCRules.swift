#if os(iOS)
import CmuxMobileLinkFFI
import CmuxScreenKit
import Foundation

/// The RFB handshake's rules (CmuxVNC's ``VNCRules``: the version banner, the security choice,
/// VNC password and Apple DH authentication) answered by cmux-vnc through cmux-mobile-link-ffi's
/// `vnc_json`, set on every ``ScreenSession`` this package makes.
enum ScreenSharingVNCRules {
    static let rules = VNCRules { operation, request in
        guard let answer = try? vncJson(operation: operation, request: String(decoding: request, as: UTF8.self)) else {
            return nil
        }
        return Data(answer.utf8)
    }
}
#endif
