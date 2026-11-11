// DEBUG builds only: no demo plumbing ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxMobileScreenSharing
public import SwiftUI

/// The app's entry to the Screen Sharing viewer demo (`-CmuxMobileScreenSharingDemo`,
/// see `ScreenSharingDemoRoot`).
public struct ShellScreenSharingDemo: View {
    public init() {}

    public static var isRequested: Bool { ScreenSharingDemoRoot.isRequested || ScreenSharingConnectDemoRoot.isRequested }

    public var body: some View {
        if ScreenSharingConnectDemoRoot.isRequested { ScreenSharingConnectDemoRoot() } else { ScreenSharingDemoRoot() }
    }
}
#endif
