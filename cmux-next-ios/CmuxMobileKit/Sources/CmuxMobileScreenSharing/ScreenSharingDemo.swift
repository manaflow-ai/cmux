// DEBUG builds only: no demo plumbing ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxScreenKit
import CmuxScreenKitUI
public import SwiftUI

/// `-CmuxMobileScreenSharingDemo`: the Screen Sharing viewer, with the same
/// chrome the real viewer shows, on the built-in demo desktop (a loopback
/// screen server in this app), so the viewer's controls can be tried and
/// UI-tested without a Mac. With `-CmuxMobileScreenSharingFollowDemo` too,
/// Follow mode follows scripted typing (`ScreenSharingFollowDemo`).
public struct ScreenSharingDemoRoot: View {
    @State private var session = ScreenSession(demoPreferences: ScreenPreferences())
    @State private var follow = ScreenSharingFollowDemo.isRequested ? ScreenSharingFollowDemo() : nil

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileScreenSharingDemo") }

    public var body: some View {
        // The Follow demo shows the screen at the phone's full height (no trackpad under it).
        ScreenSessionView(session: session, features: follow == nil ? ScreenSharingViewerScreen.features
                              : ScreenSharingViewerScreen.features.subtracting(.trackpadOverlay)) {}
            .onAppear {
                // Turns with the phone like the real viewer.
                ScreenSharingOrientation.shared.begin()
                follow?.start(session)
                session.connect()
            }
            .onDisappear {
                follow?.stop()
                ScreenSharingOrientation.shared.end()
            }
    }
}
#endif
