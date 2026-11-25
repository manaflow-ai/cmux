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
/// `-CmuxMobileScreenSharingDemoSource locked|asleep`
/// shows the Mac-is-locked / display-asleep notice, placed by
/// `-CmuxMobileScreenSharingDemoNotice banner|card|toolbar` (the gallery).
public struct ScreenSharingDemoRoot: View {
    @State private var session = ScreenSession(demoPreferences: ScreenPreferences())
    @State private var follow = ScreenSharingFollowDemo.isRequested ? ScreenSharingFollowDemo() : nil

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileScreenSharingDemo") }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var sourceState: ScreenSourceState? {
        argument(after: "-CmuxMobileScreenSharingDemoSource").flatMap(ScreenSourceState.init(rawValue:))
    }

    private static var noticePlacement: ScreenSourceNoticePlacement {
        argument(after: "-CmuxMobileScreenSharingDemoNotice").flatMap(ScreenSourceNoticePlacement.init(rawValue:)) ?? .banner
    }

    public var body: some View {
        // The Follow demo shows the screen at the phone's full height (no trackpad under it).
        ScreenSessionView(session: session, features: follow == nil ? ScreenSharingViewerScreen.features
                              : ScreenSharingViewerScreen.features.subtracting(.trackpadOverlay),
                          sourceNotice: Self.noticePlacement) {}
            .onAppear {
                // Turns with the phone like the real viewer.
                ScreenSharingOrientation.shared.begin()
                follow?.start(session)
                session.connect()
                if let state = Self.sourceState { session.receiveSourceState(state) }
            }
            .onDisappear {
                follow?.stop()
                ScreenSharingOrientation.shared.end()
            }
    }
}
#endif
