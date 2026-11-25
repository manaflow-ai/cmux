// DEBUG builds only: no demo plumbing ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxScreenKit
import CmuxScreenKitUI
public import SwiftUI

/// `-CmuxMobileScreenSharingDemo`: the Screen Sharing viewer, with the same
/// chrome the real viewer shows, on the built-in demo desktop (a loopback
/// screen server in this app), so the viewer's controls can be tried and
/// UI-tested without a Mac. `-CmuxMobileScreenSharingDemoSource locked|asleep`
/// shows the Mac-is-locked / display-asleep notice, placed by
/// `-CmuxMobileScreenSharingDemoNotice banner|card|toolbar` (the gallery).
public struct ScreenSharingDemoRoot: View {
    @State private var session = ScreenSession(demoPreferences: ScreenPreferences())

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
        ScreenSessionView(session: session, features: ScreenSharingViewerScreen.features,
                          sourceNotice: Self.noticePlacement) {}
            .onAppear {
                // Turns with the phone like the real viewer.
                ScreenSharingOrientation.shared.begin()
                session.connect()
                if let state = Self.sourceState { session.receiveSourceState(state) }
            }
            .onDisappear { ScreenSharingOrientation.shared.end() }
    }
}
#endif
