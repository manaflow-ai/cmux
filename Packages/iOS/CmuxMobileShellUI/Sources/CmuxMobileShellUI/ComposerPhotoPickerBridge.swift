import CmuxMobileShell
import Observation
import PhotosUI
import SwiftUI

/// Shared state between the accessory-hosted composer and the app-window
/// picker anchor.
///
/// The composer band rides inside the keyboard dock accessory (the system
/// keyboard's window). A `.photosPicker` attached there presents from a
/// keyboard-window controller and never cleanly tears down: the app window's
/// accessibility tree stays pruned and the dismissal binding never delivers,
/// wedging the input session's modal phase with the dock unmounted. The
/// attach button therefore only flips ``isPresented`` here; the picker itself
/// is presented by ``ComposerPhotoPickerAnchorView``, hosted in the APP
/// window, and the staged ``selection`` flows back to the composer.
@Observable
@MainActor
public final class ComposerPhotoPickerBridge {
    /// Drives the anchor's `.photosPicker` presentation.
    var isPresented = false
    /// The picked items, staged by the composer's existing pipeline and
    /// cleared after each batch so re-picking the same asset fires again.
    var selection: [PhotosPickerItem] = []

    public init() {}
}

/// Invisible app-window view that owns the composer's Photos picker
/// presentation; see ``ComposerPhotoPickerBridge``.
struct ComposerPhotoPickerAnchorView: View {
    @Bindable var bridge: ComposerPhotoPickerBridge
    /// Mirror of the input-session picker lifecycle hooks the composer's
    /// previous inline `.photosPicker` drove.
    let didPresent: () -> Void
    let didDismiss: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .photosPicker(
                isPresented: $bridge.isPresented,
                selection: $bridge.selection,
                maxSelectionCount: CMUXMobileShellStore.maxPendingAttachmentCount,
                matching: .images
            )
            .onChange(of: bridge.isPresented) { _, isPresented in
                if isPresented {
                    didPresent()
                } else {
                    didDismiss()
                }
            }
    }
}
