import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
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
/// (`WindowRootView`) in the default dark and light themes, and holds the result to
/// `schemas/theme/chrome-layer-colors.json`, the colours of the base build. A change to any chrome-layer token
/// fails here until that file is rewritten, and the pre-push gate's "Chrome layer look" rule refuses a commit
/// that rewrites it without a `Chrome-Look-OK:` trailer quoting Leo. `AAChromeLayerGalleryTests` draws the same
/// windows on a display worker and checks the pixels.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChromeLayerColorTests {
    static let path = AANestedGroupsGalleryTests.repoRoot.appending(path: "schemas/theme/chrome-layer-colors.json")
    /// The app's default themes (`GhosttyRuntime.defaultDarkThemeName`, `.defaultLightThemeName`).
    static let themes: [(name: String, dark: Bool)] = [("Apple System Colors", true), ("Apple System Colors Light", false)]
    static let regions = ["sidebar", "footer", "titlebar"]
    static let dimKey = "sidebar.surfaceDim.dark"

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
    /// shape fill that covers the point, in drawing order, at its opacity.
    static func paint(_ layer: CALayer, at point: CGPoint, over color: inout ThemeRGB, opacity: Float = 1) {
        let alpha = opacity * layer.opacity
        guard !layer.isHidden, alpha > 0.001 else { return }
        let inside = layer.bounds.contains(point)
        if inside, let background = layer.backgroundColor, let fill = rgb(background, opacity: alpha) {
            color = fill.composited(over: color)
        }
        if let shape = layer as? CAShapeLayer, let path = shape.path, let shapeFill = shape.fillColor,
           path.contains(point, using: shape.fillRule == .evenOdd ? .evenOdd : .winding), let fill = rgb(shapeFill, opacity: alpha) {
            color = fill.composited(over: color)
        }
        if layer.masksToBounds, !inside { return }
        for sublayer in layer.sublayers ?? [] {
            paint(sublayer, at: layer.convert(point, to: sublayer), over: &color, opacity: alpha)
        }
    }

    /// The colour the window shows at `point` (root coordinates): every layer over the window's surface.
    static func painted(at point: CGPoint, in root: WindowRootView) -> ThemeRGB {
        var color = root.themeTokens.surfaceBackground.withAlpha(1)
        if let layer = root.layer { paint(layer, at: point, over: &color) }
        return color
    }

    static func hex(_ color: ThemeRGB) -> String { ChromeLayerHex.hex(color) }

    /// Lets the window follow its theme and tunables (the sidebar observes them asynchronously).
    static func settle(_ root: WindowRootView, until stable: () -> Bool) async {
        for step in 0..<150 {
            try? await Task.sleep(for: .milliseconds(10))
            root.layoutSubtreeIfNeeded()
            if step >= 20, stable() { return }
        }
    }

    /// Runs `body` in the app theme `name`, put back after.
    static func inTheme<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(try AANestedGroupsGalleryTests.input(name))
        return try await body()
    }

    /// One theme's row: the colour each region paints, as `#RRGGBB`.
    static func row(_ theme: (name: String, dark: Bool), dim: Double? = nil) async throws -> [String: String] {
        if let dim { TunableStore.shared.set(dimKey, .number(dim)) }
        defer { if dim != nil { TunableStore.shared.set(dimKey, nil) } }
        return try await inTheme(theme.name) {
            let (window, root) = openRoot(dark: theme.dark)
            defer { window.close() }
            let points = points(root)
            func sample() -> [String: String] {
                var row = ["theme": theme.name, "isDark": String(theme.dark)]
                for region in regions { row[region] = hex(painted(at: points[region]!, in: root)) }
                return row
            }
            var last = sample()
            await settle(root) {
                let now = sample()
                defer { last = now }
                return now == last
            }
            return sample()
        }
    }

    /// The file's rows by theme name, in the same flat shape.
    static func fileRows() throws -> [String: [String: String]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        var rows: [String: [String: String]] = [:]
        for case let item as [String: Any] in object?["cases"] as? [Any] ?? [] {
            guard let theme = item["theme"] as? String else { continue }
            var row: [String: String] = [:]
            for (key, value) in item { row[key] = (value as? Bool).map { String($0) } ?? value as? String }
            rows[theme] = row
        }
        return rows
    }

    /// The file as this suite writes it, for a change Leo asked for.
    static func fileText(_ rows: [[String: String]]) -> String {
        let cases = rows.map { row in
            "{\"theme\":\"\(row["theme"] ?? "")\",\"isDark\":\(row["isDark"] ?? "false")"
                + regions.map { ",\"\($0)\":\"\(row[$0] ?? "")\"" }.joined() + "}"
        }
        return """
            {
            "generator": "ChromeLayerColorTests (CmuxNextAppTests); its failure prints this file's new text. Rewriting it needs a Chrome-Look-OK: trailer quoting Leo (scripts/cmux-next/prepush-gate.py, Chrome layer look)",
            "checkedBy": "CmuxNextAppTests ChromeLayerColorTests (the layers each region paints), AAChromeLayerGalleryTests (the pixels, on a display worker)",
            "regions": "sidebar: the list's leading inset halfway down; footer: the footer band's leading inset; titlebar: the top row over the main column",
            "cases": [
            \(cases.joined(separator: ",\n"))
            ]
            }

            """
    }

    @Test func theChromeLayerPaintsTheRecordedColoursInTheDefaultThemes() async throws {
        var rows: [[String: String]] = []
        for theme in Self.themes { rows.append(try await Self.row(theme)) }
        let file = try Self.fileRows()
        let differences = rows.compactMap { row -> String? in
            let name = row["theme"] ?? ""
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

    /// #39984's dim at its shipped 0.2 repaints the sidebar list and footer away from the titlebar, and this
    /// suite's recorded colours catch it: the detector holds for the change that slipped through.
    @Test func theSidebarDimFromPR39984RepaintsTheChromeLayerAndIsCaught() async throws {
        let theme = Self.themes[0]
        let plain = try await Self.row(theme)
        let dimmed = try await Self.row(theme, dim: 0.2)
        #expect(dimmed["sidebar"] != plain["sidebar"], "a 0.2 sidebar dim painted no differently: \(dimmed)")
        #expect(dimmed["sidebar"] != dimmed["titlebar"], "the dimmed sidebar matched the titlebar: \(dimmed)")
        let file = try Self.fileRows()
        #expect(file[theme.name] != dimmed, "the recorded colours would not catch the dim: \(dimmed)")
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
