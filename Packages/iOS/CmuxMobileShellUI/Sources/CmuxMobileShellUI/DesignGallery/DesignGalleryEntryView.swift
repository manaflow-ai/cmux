#if DEBUG
import SwiftUI

/// The root view for the DEBUG `CMUX_DESIGN_GALLERY` environment entry point.
///
/// Mounts the gallery root list for `CMUX_DESIGN_GALLERY=1`, or jumps straight
/// to one candidate's page for deep values such as `phosphor:specimen:dark`
/// (see ``DesignGalleryRoute`` for the grammar). Deep routing exists so
/// screenshot sweeps and UI tests can capture every candidate page without
/// scripting taps through the gallery navigation.
///
/// ```swift
/// // In the app's DEBUG root override chain:
/// DesignGalleryEntryView(environmentValue: galleryValue)
/// ```
public struct DesignGalleryEntryView: View {
    private let route: DesignGalleryRoute?

    /// Creates the entry view from the raw `CMUX_DESIGN_GALLERY` value.
    /// - Parameter environmentValue: The environment-variable value; any
    ///   non-empty, non-`0` value mounts the gallery.
    public init(environmentValue: String) {
        self.route = DesignGalleryRoute(environmentValue: environmentValue)
    }

    public var body: some View {
        if let route, let system = route.system {
            NavigationStack {
                DesignGalleryShell(
                    system: system,
                    initialPage: route.page,
                    initialScheme: route.scheme
                )
            }
        } else {
            DesignGalleryScreen()
        }
    }
}
#endif
