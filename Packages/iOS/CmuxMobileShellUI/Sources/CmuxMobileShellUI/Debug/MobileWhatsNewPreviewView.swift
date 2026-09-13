#if os(iOS) && DEBUG
import SwiftUI

/// Deterministic What's New host for screenshot checks. It renders the same
/// native sheet view the app presents after update, but does not require a
/// signed-in or paired app session.
public struct MobileWhatsNewPreviewView: View {
    @State private var showsSheet = true

    public init() {}

    public var body: some View {
        Color.clear
            .sheet(isPresented: $showsSheet) {
                MobileWhatsNewSheet(
                    pages: [MobileWhatsNewCatalog.connectionsUpdate],
                    allowedWebHosts: [],
                    dismiss: {}
                )
            }
    }
}
#endif
