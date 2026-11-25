import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one column of a sheet, a `sidebar.density` at a
/// `sidebar.textSize`, and for the favicon styles sheet a `sidebar.faviconStyle` (Lawrence msg 19869). ``all`` lists every
/// density and text size pair, densities outermost, so each density's three text sizes sit together;
/// ``favicons(_:)`` lists the same pairs drawn with one favicon style, a favicon styles sheet's columns.
nonisolated struct SidebarStatesPlaygroundColumn: Hashable, Sendable {
    /// The column's `sidebar.density`.
    var density: SidebarDensity
    /// The column's `sidebar.textSize`.
    var textSize: SidebarTextSize
    /// The `sidebar.faviconStyle` the column's sidebar draws with; nil keeps the app's own.
    var faviconStyle: SidebarFaviconStyle?

    /// Creates a column for one density and one text size.
    /// - Parameters:
    ///   - density: The `sidebar.density` the column's sidebar lays out with.
    ///   - textSize: The `sidebar.textSize` the column's sidebar lays out with.
    ///   - faviconStyle: The `sidebar.faviconStyle` the column's sidebar draws favicons with; nil keeps the app's own.
    init(density: SidebarDensity, textSize: SidebarTextSize, faviconStyle: SidebarFaviconStyle? = nil) {
        self.density = density
        self.textSize = textSize
        self.faviconStyle = faviconStyle
    }

    /// Every density at every text size: compact (default, large, larger), then comfortable, then expanded.
    static var all: [SidebarStatesPlaygroundColumn] {
        SidebarDensity.allCases.flatMap { density in SidebarTextSize.allCases.map { Self(density: density, textSize: $0) } }
    }

    /// Every density at every text size drawn with favicon style `style`: one favicon styles sheet's columns, in
    /// ``all``'s order.
    static func favicons(_ style: SidebarFaviconStyle) -> [SidebarStatesPlaygroundColumn] {
        all.map { Self(density: $0.density, textSize: $0.textSize, faviconStyle: style) }
    }

    /// The column's caption ("Compact · Large"); a favicon styles sheet names its style in its title.
    var title: String {
        String(format: String(localized: "sidebar.statesPlayground.column", defaultValue: "%1$@ · %2$@", bundle: .module),
               Self.title(density), Self.title(textSize))
    }

    static func title(_ density: SidebarDensity) -> String {
        switch density {
        case .compact: String(localized: "sidebar.statesPlayground.density.compact", defaultValue: "Compact", bundle: .module)
        case .comfortable:
            String(localized: "sidebar.statesPlayground.density.comfortable", defaultValue: "Comfortable", bundle: .module)
        case .expanded: String(localized: "sidebar.statesPlayground.density.expanded", defaultValue: "Expanded", bundle: .module)
        }
    }

    static func title(_ style: SidebarFaviconStyle) -> String {
        switch style {
        case .current: String(localized: "sidebar.statesPlayground.faviconStyle.current", defaultValue: "Current (as fetched)", bundle: .module)
        case .adaptive:
            String(localized: "sidebar.statesPlayground.faviconStyle.adaptive", defaultValue: "Adaptive tint (default)", bundle: .module)
        case .invertDark:
            String(localized: "sidebar.statesPlayground.faviconStyle.invertDark", defaultValue: "Invert dark mono", bundle: .module)
        case .plate: String(localized: "sidebar.statesPlayground.faviconStyle.plate", defaultValue: "Rounded plate", bundle: .module)
        case .circlePlate:
            String(localized: "sidebar.statesPlayground.faviconStyle.circlePlate", defaultValue: "Circular plate", bundle: .module)
        case .monochrome:
            String(localized: "sidebar.statesPlayground.faviconStyle.monochrome", defaultValue: "All in label colour", bundle: .module)
        case .hiRes: String(localized: "sidebar.statesPlayground.faviconStyle.hiRes", defaultValue: "Hi-res, untreated", bundle: .module)
        }
    }

    static func title(_ size: SidebarTextSize) -> String {
        switch size {
        case .standard: String(localized: "sidebar.statesPlayground.textSize.default", defaultValue: "Default text", bundle: .module)
        case .large: String(localized: "sidebar.statesPlayground.textSize.large", defaultValue: "Large text", bundle: .module)
        case .larger: String(localized: "sidebar.statesPlayground.textSize.larger", defaultValue: "Larger text", bundle: .module)
        }
    }
}
