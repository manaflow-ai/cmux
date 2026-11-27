import SwiftUI

extension View {
    /// Attach a standard pull-to-refresh gesture that runs `refresh` when present.
    ///
    /// `refresh` must `await` the real workspace-list re-sync so SwiftUI's system
    /// refresh spinner stays up until the round-trip actually completes (or fails),
    /// matching native `refreshable` behavior. When `refresh` is `nil` (previews,
    /// or a host with no live re-sync), no gesture is attached.
    ///
    /// On macOS, `.refreshable` decorates an `EditButton`-style affordance rather
    /// than a drag gesture, so this is gated to iOS where pull-to-refresh is the
    /// expected interaction for the workspace list.
    @ViewBuilder
    func workspaceListRefreshable(_ refresh: (@Sendable () async -> Void)?) -> some View {
        #if os(iOS)
        if let refresh {
            self.refreshable { await refresh() }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
