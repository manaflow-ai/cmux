// DEBUG builds only: no eval viewer ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxMobileScreenSharing
public import SwiftUI

/// The app's entry to the Mac screen over a cmux link with no sign-in (`CMUX_MOBILE_RD_LINK`, see
/// `ScreenSharingRdLinkRoot`): the screen-stream eval's iphone-link viewer.
public struct ShellScreenSharingRdLink: View {
    public init() {}

    public static var isRequested: Bool { ScreenSharingRdLinkRoot.isRequested }

    public var body: some View { ScreenSharingRdLinkRoot() }
}
#endif
