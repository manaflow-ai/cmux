import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The chrome layer (sidebar list, sidebar footer, titlebar) keeps its colour unless Leo asks.
///
/// #39984 laid a 20% black dim on the sidebar (`SidebarStyle.surfaceDim`) for a non-Leo issue, and in the
/// nightly the list read a step darker than the footer, the update card and the titlebar. Leo, 2026-11-11:
/// "bro why is the sidebar now a different color?" #41047 set the dim back to 0. `SidebarSurfaceTests`
/// passed through it because it reads the window surface and the main pane's shade, not the sidebar clip's
/// own fill. This suite reads what every layer over each region paints (`painted(at:in:)`: each layer's
/// background and shape fill, composited in drawing order over the window's surface), in a whole window
/// (`WindowRootView`) in the default dark and light themes, each plain and over a background picture, and
/// holds the result to `schemas/theme/chrome-layer-colors.json`, the colours of the base build. A change to
/// any chrome-layer token fails here until that file is rewritten, and the pre-push gate's "Chrome layer look"
/// rule refuses a commit that rewrites it without a `Chrome-Look-OK:` trailer quoting Leo.
/// `AAChromeLayerGalleryTests` draws the same windows on a display worker and checks the pixels.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChromeLayerColorTests {
    /// One recorded window: a default theme, plain or over a background picture.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let theme: String
        let dark: Bool
        /// The background picture (`appearance.background`); nil for the plain window.
        let art: BackdropArt?
        var testDescription: String { name }
    }

    static let path = AANestedGroupsGalleryTests.repoRoot.appending(path: "schemas/theme/chrome-layer-colors.json")
    /// The app's default themes (`GhosttyRuntime.defaultDarkThemeName`, `.defaultLightThemeName`), plain and over
    /// a picture.
    nonisolated static let cases = [
        Case(name: "dark", theme: "Apple System Colors", dark: true, art: nil),
        Case(name: "light", theme: "Apple System Colors Light", dark: false, art: nil),
        Case(name: "dark-image", theme: "Apple System Colors", dark: true, art: .vanGoghStarryNight),
        Case(name: "light-image", theme: "Apple System Colors Light", dark: false, art: .vanGoghStarryNight),
    ]
    static let regions = ["sidebar", "footer", "titlebar"]
    static let dimKeys = (dark: "sidebar.surfaceDim.dark", light: "sidebar.surfaceDim.light")
    /// What the walk composites where the background picture shows: one fixed mid grey, so a region's colour over
    /// a picture is the tint and the chrome layers over it, the same on every machine. The gallery's stills show the
    /// real picture.
    static let pictureStandIn = ThemeRGB(red: 0.5, green: 0.5, blue: 0.5)

    /// A whole window as the app opens it: titled, full-size content, the sidebar shown with rows in it.
    static func openRoot(dark: Bool) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: AASidebarLookGalleryTests.sections())
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    /// Where each region is sampled, in root coordinates: the sidebar list's leading inset halfway down (no row
    /// fill or text reaches it), the footer band's leading inset, and the titlebar row over the main column.
    static func points(_ root: WindowRootView) -> [String: CGPoint] {
        let side = root.sidebar.frame
        let x = side.minX + 3
        return [
            "sidebar": CGPoint(x: x, y: side.midY),
            "footer": CGPoint(x: x, y: root.isFlipped ? side.maxY - 10 : side.minY + 10),
            "titlebar": CGPoint(x: root.contentHost.frame.midX, y: root.isFlipped ? root.bounds.minY + 1 : root.bounds.maxY - 1),
        ]
    }

    static func rgb(_ color: CGColor, opacity: Float) -> ThemeRGB? {
        guard let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent),
                        alpha: Double(c.alphaComponent) * Double(opacity))
    }

    /// `layer` and its sublayers painted over `color` at `point` (layer coordinates): each background and
    /// shape fill that covers the point, in drawing order, at its opacity; `picture` (the backdrop's art layer)
    /// paints ``pictureStandIn``.
    static func paint(_ layer: CALayer, at point: CGPoint, over color: inout ThemeRGB, opacity: Float = 1, picture: CALayer?) {
        let alpha = opacity * layer.opacity
        guard !layer.isHidden, alpha > 0.001 else { return }
        let inside = layer.bounds.contains(point)
        if inside, let background = layer.backgroundColor, let fill = rgb(background, opacity: alpha) {
            color = fill.composited(over: color)
        }
        if inside, let picture, layer === picture, layer.contents != nil {
            color = pictureStandIn.withAlpha(Double(alpha)).composited(over: color)
        }
        if let shape = layer as? CAShapeLayer, let path = shape.path, let shapeFill = shape.fillColor,
           path.contains(point, using: shape.fillRule == .evenOdd ? .evenOdd : .winding), let fill = rgb(shapeFill, opacity: alpha) {
            color = fill.composited(over: color)
        }
        if layer.masksToBounds, !inside { return }
        for sublayer in layer.sublayers ?? [] {
            paint(sublayer, at: layer.convert(point, to: sublayer), over: &color, opacity: alpha, picture: picture)
        }
    }

    /// The colour the window shows at `point` (root coordinates): every layer over the window's surface.
    static func painted(at point: CGPoint, in root: WindowRootView) -> ThemeRGB {
        var color = root.themeTokens.surfaceBackground.withAlpha(1)
        let art = root.backdropView.artView
        if let layer = root.layer { paint(layer, at: point, over: &color, picture: art.isHidden ? nil : art.layer) }
        return color
    }

    static func hex(_ color: ThemeRGB) -> String { ChromeLayerHex.hex(color) }

    /// Lets the window follow its theme, picture and tunables (the sidebar observes them asynchronously).
    static func settle(_ root: WindowRootView, until stable: @MainActor () -> Bool) async {
        for step in 0..<300 {
            try? await Task.sleep(for: .milliseconds(10))
            root.layoutSubtreeIfNeeded()
            if step >= 20, stable() { return }
        }
    }

    /// Runs `body` in the app theme `name` with `art` as the app's background picture, both put back after.
    static func inCase<T>(_ item: Case, _ body: @MainActor () async throws -> T) async throws -> T {
        let original = ThemeScope.app.store.input
        let originalSelection = ThemeScope.app.backdropSelection
        defer {
            _ = ThemeScope.app.store.apply(original)
            ThemeScope.app.setBackdropSelection(originalSelection)
        }
        _ = ThemeScope.app.store.apply(try AANestedGroupsGalleryTests.input(item.theme))
        ThemeScope.app.setBackdropSelection(item.art.map { .art($0) })
        return try await body()
    }

    /// Runs `body` with #39984's dim (`dim` dark, a eighth of it light, as it shipped: 0.2 and 0.025), put back
    /// after; `nil` runs it with the dim as the tree has it.
    static func withDim<T>(_ dim: Double?, _ body: @MainActor () async throws -> T) async rethrows -> T {
        guard let dim else { return try await body() }
        TunableStore.shared.set(dimKeys.dark, .number(dim))
        TunableStore.shared.set(dimKeys.light, .number(dim / 8))
        defer {
            TunableStore.shared.set(dimKeys.dark, nil)
            TunableStore.shared.set(dimKeys.light, nil)
        }
        return try await body()
    }

    /// One case's row: the colour each region paints, as `#RRGGBB`.
    static func row(_ item: Case, dim: Double? = nil) async throws -> [String: String] {
        try await withDim(dim) {
            try await inCase(item) {
                let (window, root) = Self.openRoot(dark: item.dark)
                defer { window.close() }
                root.themeDidChange()
                let spots = Self.points(root)
                @MainActor func sample() -> [String: String] {
                    var row = ["case": item.name, "theme": item.theme, "isDark": String(item.dark),
                               "background": item.art?.rawValue ?? "none"]
                    for region in Self.regions { row[region] = Self.hex(Self.painted(at: spots[region]!, in: root)) }
                    return row
                }
                var last = sample()
                await Self.settle(root) {
                    let now = sample()
                    defer { last = now }
                    return now == last && (item.art == nil || !root.backdropView.artView.isHidden)
                }
                if item.art != nil {
                    #expect(!root.backdropView.artView.isHidden, "\(item.name): the window never showed its picture")
                }
                return sample()
            }
        }
    }

    /// The file's rows by case name, in the same flat shape.
    static func fileRows() throws -> [String: [String: String]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        var rows: [String: [String: String]] = [:]
        for case let item as [String: Any] in object?["cases"] as? [Any] ?? [] {
            guard let name = item["case"] as? String else { continue }
            var row: [String: String] = [:]
            for (key, value) in item { row[key] = (value as? Bool).map { String($0) } ?? value as? String }
            rows[name] = row
        }
        return rows
    }

    /// The file as this suite writes it, for a change Leo asked for.
    static func fileText(_ rows: [[String: String]]) -> String {
        let cases = rows.map { row in
            "{\"case\":\"\(row["case"] ?? "")\",\"theme\":\"\(row["theme"] ?? "")\",\"isDark\":\(row["isDark"] ?? "false"),"
                + "\"background\":\"\(row["background"] ?? "none")\""
                + regions.map { ",\"\($0)\":\"\(row[$0] ?? "")\"" }.joined() + "}"
        }
        return """
            {
            "generator": "ChromeLayerColorTests (CmuxNextAppTests); its failure prints this file's new text. Rewriting it needs a Chrome-Look-OK: trailer quoting Leo (scripts/cmux-next/prepush-gate.py, Chrome layer look)",
            "checkedBy": "CmuxNextAppTests ChromeLayerColorTests (the layers each region paints), AAChromeLayerGalleryTests (the pixels, on a display worker), webviews/test/chrome-layer-colors.test.ts (the gallery's mock app)",
            "regions": "sidebar: the list's leading inset halfway down; footer: the footer band's leading inset; titlebar: the top row over the main column. Over a background picture the picture counts as #808080",
            "cases": [
            \(cases.joined(separator: ",\n"))
            ]
            }

            """
    }

    @Test func theChromeLayerPaintsTheRecordedColoursInTheDefaultThemes() async throws {
        var rows: [[String: String]] = []
        for item in Self.cases { rows.append(try await Self.row(item)) }
        let file = try Self.fileRows()
        let differences = rows.compactMap { row -> String? in
            let name = row["case"] ?? ""
            return file[name] == row ? nil : "\(name): recorded \(file[name]?.description ?? "none"), painted \(row)"
        }
        #expect(differences.isEmpty, """
            The chrome layer (sidebar, footer, titlebar) paints a different colour from \(Self.path.path).
            The chrome keeps its colour unless Leo asks (#39984, #41047). If he did, write this text to the file and \
            quote him in a `Chrome-Look-OK:` trailer:
            \(Self.fileText(rows))
            \(differences.joined(separator: "\n"))
            """)
    }

    /// The sidebar list, its footer and the titlebar are one surface: each case paints them one colour.
    @Test func theSidebarFooterAndTitlebarAreOneColour() throws {
        for (name, row) in try Self.fileRows() {
            #expect(row["sidebar"] == row["titlebar"] && row["footer"] == row["titlebar"], "\(name): \(row)")
        }
    }

    /// #39984's dim at its shipped 0.2 (0.025 light) repaints the sidebar list away from the titlebar, plain and
    /// over a picture, and this suite's recorded colours catch it: the detector holds for the change that slipped
    /// through.
    @Test(arguments: [cases[0], cases[1], cases[2]])
    func theSidebarDimFromPR39984RepaintsTheChromeLayerAndIsCaught(_ item: Case) async throws {
        let plain = try await Self.row(item)
        let dimmed = try await Self.row(item, dim: 0.2)
        #expect(dimmed["sidebar"] != plain["sidebar"], "\(item.name): a 0.2 sidebar dim painted no differently: \(dimmed)")
        #expect(dimmed["sidebar"] != dimmed["titlebar"], "\(item.name): the dimmed sidebar matched the titlebar: \(dimmed)")
        let file = try Self.fileRows()
        #expect(file[item.name] != dimmed, "\(item.name): the recorded colours would not catch the dim: \(dimmed)")
    }
}

/// `#RRGGBB`, each channel rounded half away from zero, as `schemas/theme/theme-ink-vectors.json` writes it.
enum ChromeLayerHex {
    static func hex(_ color: ThemeRGB) -> String {
        "#" + [color.red, color.green, color.blue].map { channel in
            let text = String(Int((min(max(channel, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return text.count < 2 ? "0" + text : text
        }.joined()
    }
}
