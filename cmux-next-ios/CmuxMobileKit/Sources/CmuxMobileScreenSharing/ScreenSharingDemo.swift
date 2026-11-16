// DEBUG builds only: no demo plumbing ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxScreenKit
import CmuxScreenKitUI
public import SwiftUI

/// `-CmuxMobileScreenSharingDemo`: the Screen Sharing viewer, with the same
/// chrome the real viewer shows, on the built-in demo desktop (a loopback
/// screen server in this app), so the viewer's controls can be tried and
/// UI-tested without a Mac.
public struct ScreenSharingDemoRoot: View {
    @State private var session = ScreenSession(demoPreferences: ScreenPreferences())

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileScreenSharingDemo") }

    public var body: some View {
        ScreenSessionView(session: session, features: ScreenSharingViewerScreen.features) {}
            .onAppear {
                // Turns with the phone like the real viewer.
                ScreenSharingOrientation.shared.begin()
                session.connect()
            }
            .onDisappear { ScreenSharingOrientation.shared.end() }
    }
}
#endif
