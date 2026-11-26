#if os(iOS) && DEBUG
import SwiftUI
import Foundation
import CmuxMobileShellModel

/// Deterministic What's New host for screenshot checks. It renders the same
/// native sheet view the app presents after update, but does not require a
/// signed-in or paired app session.
public struct MobileWhatsNewPreviewView: View {
    @State private var showsSheet: Bool
    @State private var center: MobileWhatsNewCenter
    private let hasRemoteFixture: Bool

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let payload = environment["CMUX_UITEST_WHATS_NEW_PAYLOAD"]
        let defaults = UserDefaults(suiteName: "MobileWhatsNewPreview-\(UUID().uuidString)")!
        if let marker = environment["CMUX_UITEST_WHATS_NEW_ACKNOWLEDGED_ENTRY_ID"] {
            defaults.set(marker, forKey: MobileWhatsNewCenter.markerKey)
        }
        hasRemoteFixture = payload != nil
        _showsSheet = State(initialValue: payload == nil)
        _center = State(initialValue: MobileWhatsNewCenter(
            apiBaseURL: "https://cmux.test",
            appVersion: environment["CMUX_UITEST_WHATS_NEW_VERSION"] ?? "1.0.5",
            buildType: MobileBuildType(rawValue: environment["CMUX_UITEST_WHATS_NEW_CHANNEL"] ?? "dev") ?? .dev,
            defaults: defaults,
            loader: { _ in
                guard let payload else { throw URLError(.notConnectedToInternet) }
                return Data(payload.utf8)
            }
        ))
    }

    public var body: some View {
        NavigationStack {
            MobileWhatsNewListView()
        }
            .overlay(alignment: .bottom) {
                if hasRemoteFixture && center.lastRefreshSucceeded {
                    Text("Remote notice loaded")
                        .accessibilityIdentifier("MobileWhatsNewPreviewLoaded")
                }
            }
            .environment(center)
            .task {
                guard hasRemoteFixture else { return }
                await center.refresh()
                showsSheet = !center.unseenPages.isEmpty
            }
            .sheet(isPresented: $showsSheet) {
                MobileWhatsNewSheet(
                    pages: center.unseenPages,
                    allowedWebHosts: [],
                    dismiss: { showsSheet = false }
                )
                .environment(center)
                .preferredColorScheme(
                    ProcessInfo.processInfo.environment["CMUX_UITEST_WHATS_NEW_APPEARANCE"] == "dark"
                        ? .dark : .light
                )
            }
    }
}
#endif
