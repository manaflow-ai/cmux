public import SwiftUI

/// The browser panel's focus-flash ring: a rounded-rectangle accent stroke with
/// a soft shadow that fades in and out to flag a focus change. Non-interactive.
///
/// Renders from a ``BrowserFocusFlashSnapshot``. The app-side forwarder owns the
/// animated opacity `@State` and the ring metrics and builds the snapshot.
public struct BrowserFocusFlashOverlay: View {
    private let snapshot: BrowserFocusFlashSnapshot

    /// Creates the focus-flash ring from a snapshot.
    public init(snapshot: BrowserFocusFlashSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: snapshot.cornerRadius)
            .stroke(snapshot.accentColor.opacity(snapshot.opacity), lineWidth: 3)
            .shadow(color: snapshot.accentColor.opacity(snapshot.opacity * 0.35), radius: 10)
            .padding(snapshot.inset)
            .allowsHitTesting(false)
    }
}
