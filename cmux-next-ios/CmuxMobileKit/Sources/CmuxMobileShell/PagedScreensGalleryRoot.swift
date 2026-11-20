#if DEBUG && os(iOS)
import SwiftUI

/// The app's screens that moved to the shared infinite-scroll list (``PagedList``,
/// verify/paged-list.md), each on fixed data, for their UI tests and screenshots. Launch with
/// `-cmux-mobile-paged-screen SCREEN:SCENARIO`:
/// - `cloudchats`: a Cloud machine's chats (``CloudChatsGallery`` lists the scenarios).
/// `-cmux-mobile-gallery-appearance light|dark` picks the scheme; `-cmux-mobile-paged-lab-clean`
/// hides the measurement line and the test buttons for screenshots.
public struct PagedScreensGalleryRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-paged-screen")
    }

    let screen: String
    let scenario: String
    let scheme: ColorScheme?
    let clean: Bool

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
        }
        let parts = (value("-cmux-mobile-paged-screen") ?? "cloudchats:fast").split(separator: ":").map(String.init)
        screen = parts.first ?? "cloudchats"
        scenario = parts.count > 1 ? parts[1] : "fast"
        let look = value("-cmux-mobile-gallery-appearance")
        scheme = look == "dark" ? .dark : look == "light" ? .light : nil
        clean = arguments.contains("-cmux-mobile-paged-lab-clean")
    }

    public var body: some View {
        switch screen {
        default:
            CloudChatsGallery(scenario: scenario, scheme: scheme, clean: clean)
        }
    }
}
#endif
