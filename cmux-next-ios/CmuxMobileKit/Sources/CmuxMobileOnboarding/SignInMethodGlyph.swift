#if os(iOS)
import CmuxMobileModel
import SwiftUI

/// The glyph for a sign-in method, as the Welcome's buttons draw it: the
/// Apple, Google and GitHub marks, an envelope for an email code, and line
/// symbols for the rest. Settings → Account lists methods with it.
public struct SignInMethodGlyph: View {
    let method: SignInMethod
    let size: CGFloat

    public init(_ method: SignInMethod, size: CGFloat) {
        self.method = method
        self.size = size
    }

    public var body: some View {
        switch method {
        case .apple:
            Image(systemName: "apple.logo").font(.system(size: size + 1, weight: .medium))
        case .google:
            Image("GoogleLogo", bundle: .module).resizable().scaledToFit().frame(width: size, height: size)
        case .github:
            Image("GitHubLogo", bundle: .module).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
        case .emailCode:
            Image(systemName: "envelope").font(.system(size: size - 1))
        case .password:
            Image(systemName: "key").font(.system(size: size - 1))
        case .passkey:
            Image(systemName: "person.badge.key").font(.system(size: size - 1))
        case .oauth:
            Image(systemName: "person.crop.circle").font(.system(size: size - 1))
        }
    }
}
#endif
