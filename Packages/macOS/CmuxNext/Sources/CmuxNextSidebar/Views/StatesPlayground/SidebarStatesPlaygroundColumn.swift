import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one column of a sheet, a `sidebar.density` at a
/// `sidebar.textSize`. ``all`` lists every pair, densities outermost, so each density's three text sizes sit together.
nonisolated struct SidebarStatesPlaygroundColumn: Hashable, Sendable {
    /// The column's `sidebar.density`.
    var density: SidebarDensity
    /// The column's `sidebar.textSize`.
    var textSize: SidebarTextSize

    /// Creates a column for one density and one text size.
    /// - Parameters:
    ///   - density: The `sidebar.density` the column's sidebar lays out with.
    ///   - textSize: The `sidebar.textSize` the column's sidebar lays out with.
    init(density: SidebarDensity, textSize: SidebarTextSize) {
        self.density = density
        self.textSize = textSize
    }

    /// Every density at every text size: compact (default, large, larger), then comfortable, then expanded.
    static var all: [SidebarStatesPlaygroundColumn] {
        SidebarDensity.allCases.flatMap { density in SidebarTextSize.allCases.map { Self(density: density, textSize: $0) } }
    }

    /// The column's caption ("Compact · Large").
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

    static func title(_ size: SidebarTextSize) -> String {
        switch size {
        case .standard: String(localized: "sidebar.statesPlayground.textSize.default", defaultValue: "Default text", bundle: .module)
        case .large: String(localized: "sidebar.statesPlayground.textSize.large", defaultValue: "Large text", bundle: .module)
        case .larger: String(localized: "sidebar.statesPlayground.textSize.larger", defaultValue: "Larger text", bundle: .module)
        }
    }
}
