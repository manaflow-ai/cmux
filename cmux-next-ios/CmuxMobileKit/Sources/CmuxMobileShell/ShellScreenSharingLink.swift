// DEBUG builds only: no pairing-link viewer ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxMobileScreenSharing
public import SwiftUI

/// The app's entry to the Screen Sharing viewer on a pairing link (`CMUX_MOBILE_SS_LINK`, see
/// `ScreenSharingLinkRoot`): the screen-stream eval's iPhone viewer.
public struct ShellScreenSharingLink: View {
    public init() {}

    public static var isRequested: Bool { ScreenSharingLinkRoot.isRequested }

    public var body: some View { ScreenSharingLinkRoot() }
}
#endif
