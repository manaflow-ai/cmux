#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// A candidate visual system available in the static design gallery.
enum DesignGallerySystem: String, CaseIterable, Identifiable {
    case phosphor
    case atelier
    case meridian
    case signal

    /// The stable identifier used by gallery navigation.
    var id: String { rawValue }

    /// The presentation-order number assigned to the candidate.
    var number: String {
        switch self {
        case .phosphor: "01"
        case .atelier: "02"
        case .meridian: "03"
        case .signal: "04"
        }
    }

    /// The candidate's proper name.
    var displayName: String {
        switch self {
        case .phosphor: "Phosphor"
        case .atelier: "Atelier"
        case .meridian: "Meridian"
        case .signal: "Signal"
        }
    }

    /// The localized one-line identity of the candidate.
    var tagline: String {
        switch self {
        case .phosphor:
            L10n.string(
                "mobile.designGallery.system.phosphor.tagline",
                defaultValue: "Terminal-native instrument"
            )
        case .atelier:
            L10n.string(
                "mobile.designGallery.system.atelier.tagline",
                defaultValue: "Warm humanist companion"
            )
        case .meridian:
            L10n.string(
                "mobile.designGallery.system.meridian.tagline",
                defaultValue: "Liquid-glass native"
            )
        case .signal:
            L10n.string(
                "mobile.designGallery.system.signal.tagline",
                defaultValue: "Swiss status board"
            )
        }
    }

    /// Builds the selected page with this candidate's root gallery view.
    /// - Parameter page: The shared gallery page the candidate should render.
    /// - Returns: The candidate's static representation of `page`.
    @ViewBuilder
    func content(page: DesignGalleryPage) -> some View {
        switch self {
        case .phosphor:
            PhosphorGallery(page: page)
        case .atelier:
            AtelierGallery(page: page)
        case .meridian:
            MeridianGallery(page: page)
        case .signal:
            SignalGallery(page: page)
        }
    }
}
#endif
