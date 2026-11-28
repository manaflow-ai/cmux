#if DEBUG
import SwiftUI

/// One color over the whole screen, shown only when the app is launched with
/// CMUX_LIVE_CODE_PROBE=1. scripts/measure/ios-live-duress.py edits the color in `body` and times
/// from the saved edit to the new color in the simulator's screenshot: a Swift body edit through
/// a live patch (`ios-live swift`) against a rebuild, install and relaunch.
struct LiveCodeProbeRoot: View {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["CMUX_LIVE_CODE_PROBE"] == "1" }

    var body: some View {
        Color(red: 0.5, green: 0.5, blue: 0.5).ignoresSafeArea()
    }
}
#endif
