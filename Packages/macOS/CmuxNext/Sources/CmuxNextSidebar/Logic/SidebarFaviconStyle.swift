public import CmuxNextDesign

/// How the sidebar draws a page's favicon (Debug `sidebar.faviconStyle`; Lawrence msg 19869, "also see if we can make
/// these favicons look better": the GitHub mark drew as a dark, muddy circle on the dark sidebar).
///
/// Every style but ``current`` draws the favicon from its highest-resolution source, downsampled once to the drawn pixel
/// size with high-quality interpolation. A favicon is measured once when it first shows (`SidebarFaviconInk`); nothing
/// is measured per frame.
public nonisolated enum SidebarFaviconStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Before msg 19869: the favicon as fetched, scaled by the image view.
    case current
    /// The default: a monochrome favicon with less than 3:1 contrast on the sidebar draws as a template in the label
    /// colour; every other favicon draws as is.
    case adaptive
    /// A dark monochrome favicon on a dark sidebar draws inverted (a black mark turns white); others as is.
    case invertDark
    /// Every favicon on a subtle rounded plate: a light plate on a dark sidebar, a faint dark one on a light sidebar.
    case plate
    /// As ``plate`` on a circular plate.
    case circlePlate
    /// Every favicon, colourful or not, as a template in the label colour.
    case monochrome
    /// The high-resolution source with no colour treatment.
    case hiRes

    public var tunableTitle: String {
        switch self {
        case .current: "Current (as fetched)"
        case .adaptive: "Adaptive tint for low-contrast mono icons"
        case .invertDark: "Invert dark mono icons in dark mode"
        case .plate: "Rounded backing plate"
        case .circlePlate: "Circular backing plate"
        case .monochrome: "Every icon in the label colour"
        case .hiRes: "High-resolution source, no treatment"
        }
    }

    public static let tunable = Tunable<SidebarFaviconStyle>.choice(
        "sidebar.faviconStyle", .sidebar, "Favicon style",
        help: "How the sidebar draws a page's favicon: as fetched, a low-contrast monochrome icon tinted with the label colour (default), dark monochrome icons inverted in dark mode, every icon on a rounded or circular plate, every icon in the label colour, or the high-resolution icon untreated.",
        default: .adaptive, code: "SidebarFaviconStyle.tunable")

    /// Least contrast a monochrome favicon keeps on the sidebar before ``adaptive`` tints it (WCAG's 3:1 for marks).
    static let minimumContrast = 3.0
    /// Ground relative luminance below which the sidebar counts as dark (mid grey is about 0.18).
    static let darkGround = 0.18

    /// How a favicon with measured `ink` (nil: nothing opaque) draws on a ground of relative luminance `ground`.
    func treatment(for ink: SidebarFaviconInk?, ground: Double) -> SidebarFaviconTreatment {
        switch self {
        case .current: return .original
        case .hiRes: return .smooth
        case .monochrome: return .template
        case .plate: return .plate(circle: false)
        case .circlePlate: return .plate(circle: true)
        case .adaptive:
            guard let ink, ink.isMonochrome, ink.contrast(onGround: ground) < Self.minimumContrast else { return .smooth }
            return .template
        case .invertDark:
            guard let ink, ink.isMonochrome, ground < Self.darkGround, ink.luminance < Self.darkGround else { return .smooth }
            return .inverted
        }
    }
}
