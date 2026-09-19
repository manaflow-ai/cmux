#if os(iOS) && DEBUG
import SwiftUI
import Foundation

/// Deterministic What's New host for screenshot checks. It renders the same
/// native sheet view the app presents after update, but does not require a
/// signed-in or paired app session.
public struct MobileWhatsNewPreviewView: View {
    @State private var showsSheet = true
    @State private var center = MobileWhatsNewCenter(
        apiBaseURL: "https://cmux.test",
        buildType: .beta,
        defaults: UserDefaults(suiteName: "MobileWhatsNewPreview-\(UUID().uuidString)")!,
        loader: { _ in throw URLError(.notConnectedToInternet) }
    )

    public init() {}

    public var body: some View {
        NavigationStack {
            MobileWhatsNewListView()
        }
            .environment(center)
            .sheet(isPresented: $showsSheet) {
                MobileWhatsNewSheet(
                    pages: MobileWhatsNewCatalog.entries,
                    allowedWebHosts: [],
                    dismiss: { showsSheet = false }
                )
                .preferredColorScheme(
                    ProcessInfo.processInfo.environment["CMUX_UITEST_WHATS_NEW_APPEARANCE"] == "dark"
                        ? .dark : .light
                )
            }
    }
}
#endif
