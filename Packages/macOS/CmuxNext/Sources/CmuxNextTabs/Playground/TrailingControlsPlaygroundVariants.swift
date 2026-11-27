import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// DEV and NIGHTLY (the Debug menu): layouts of a browser pane's trailing controls (Lawrence msg 19627: "alignment of stuff
/// here is not very good ... the three vertical dots, there are 2 of them, and they are different
/// sizes"). Each row is the real strip above a toolbar row; the pink line is the tab bar ⋮'s column.
struct TrailingControlsPlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            row(String(localized: "tabs.playground.trailing.shipped", defaultValue: "One ⋮ size, one column (shipped fix)", bundle: .module),
                .shipped, shipped: true),
            row(String(localized: "tabs.playground.trailing.before", defaultValue: "Before: two ⋮ glyphs and sizes, columns 2 pt apart", bundle: .module), .before),
            row(String(localized: "tabs.playground.trailing.mergeTop", defaultValue: "One ⋮ in the tab bar: the toolbar's rows join it", bundle: .module)) {
                $0.toolbarMore = nil
            },
            row(String(localized: "tabs.playground.trailing.mergeToolbar", defaultValue: "One ⋮ in the toolbar: the tab bar's rows join it", bundle: .module)) {
                $0.tabBarMore = nil
            },
            row(String(localized: "tabs.playground.trailing.grid", defaultValue: "Toolbar buttons in the tab bar's columns, one under each", bundle: .module)) {
                $0.sharesColumns = true
            },
            row(String(localized: "tabs.playground.trailing.oneIconSize", defaultValue: "Every icon one size (16 pt) and one 24 pt hit box", bundle: .module)) {
                $0.toolbarIconSize = 16
                $0.tabBarMoreSize = 16
                $0.toolbarMoreSize = 16
                $0.toolbarButtonSide = 24
                $0.tabBarButtonSide = 24
            },
            row(String(localized: "tabs.playground.trailing.chromium", defaultValue: "Both ⋮ Chromium's glyph at the toolbar's icon size", bundle: .module)) {
                $0.tabBarMore = .browserToolbarMore
                $0.toolbarMore = .browserToolbarMore
                $0.tabBarMoreSize = $0.toolbarIconSize
                $0.toolbarMoreSize = $0.toolbarIconSize
            },
            row(String(localized: "tabs.playground.trailing.horizontal", defaultValue: "Tab bar … (pane), toolbar ⋮ (page): two roles, two glyphs", bundle: .module)) {
                $0.tabBarMore = .actionMore
            },
            row(String(localized: "tabs.playground.trailing.inset", defaultValue: "Both columns 4 pt further in, away from the pane's edge", bundle: .module)) {
                $0.tabBarColumn += Metrics.space2
                $0.toolbarColumn += Metrics.space2
            },
        ]
    }

    private func row(_ name: String, _ spec: TabBarPlaygroundTrailingSpec = .shipped, shipped: Bool = false,
                     adjust: ((inout TabBarPlaygroundTrailingSpec) -> Void)? = nil) -> TabBarPlaygroundVariant {
        let fixture = fixture
        var spec = spec
        adjust?(&spec)
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            TabBarPlaygroundTrailingRows(spec: spec, strip: fixture.strip(count: count, showsNewTabButton: false))
        }
    }
}
