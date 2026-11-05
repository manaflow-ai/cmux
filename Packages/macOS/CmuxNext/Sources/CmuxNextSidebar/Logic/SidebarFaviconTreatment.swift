/// How one favicon draws in the sidebar's icon column, chosen by ``SidebarFaviconStyle`` from the favicon's measured
/// ink (`SidebarFaviconInk`) and the sidebar ground under it.
nonisolated enum SidebarFaviconTreatment: Hashable, Sendable {
    /// The source image handed to the image view as is (before Lawrence msg 19869).
    case original
    /// The highest-resolution source, downsampled once to the drawn pixel size with high-quality interpolation.
    case smooth
    /// ``smooth``, drawn as a template in the row's label colour (its alpha is the shape).
    case template
    /// ``smooth`` with its colours inverted (a black mark turns white), alpha kept.
    case inverted
    /// ``smooth``, inset on a plate behind it: a rounded square, or a circle when `circle`.
    case plate(circle: Bool)

    /// Whether the image draws on a plate.
    var hasPlate: Bool { if case .plate = self { true } else { false } }
}
