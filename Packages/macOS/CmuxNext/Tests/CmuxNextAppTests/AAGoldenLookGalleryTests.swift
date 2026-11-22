import AppKit
import CmuxNextActions
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The native half of the golden look screen (`looks.golden`, `bun run golden:looks`): for each look in
/// `webviews/src/gallery/golden/looks.json`, light and dark, the real NEXT sidebar list (two project groups and a
/// loose row: one selected, one unread, one working, one needing input, ages where the look turns
/// `sidebar.showTimestamps` on) beside a tab strip of four tabs (one selected) over its pane, drawn under the look.
///
/// A look is applied as the app applies a setup: its settings (`settings`, or a setup folder's `cmux-setup.json`)
/// are the config file, the scheme's theme file (inline `theme`, a repo `themeFile`, or the setup's
/// `themes/<appearance.themeFile>.json` for the scheme its colors are) goes over it through `ThemeFileOverlay`, the
/// result is parsed by `CmuxConfigSnapshot` and applied by `SettingsApplier` (density, `sidebar.*`, status style),
/// and its theme (`appearance.theme` with the file's colors as `appearance.themeEdits`), accent and
/// `appearance.surfaces` go to the theme scope. A scheme with no theme draws cmux's default (Apple System Colors
/// Light / Apple System Colors). A look whose files are missing in the checkout is skipped and named in `notes.txt`.
///
/// Every image is the same size (`size` points at 2x: 1360 x 880 pixels), so a sheet places them in a column.
/// Written under `golden-look-gallery/` as `<look>-<light|dark>.png`, with `all.png` (one row per look, light then
/// dark) and `notes.txt`, bundled to `golden-look-gallery.tar` for `cmux-ci run --artifact`. `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAGoldenLookGalleryTests {
    /// The image in points: the sidebar column, then the tab strip over its pane.
    static let size = CGSize(width: 680, height: 440)
    static let sidebarWidth: CGFloat = 260
    static let scale: CGFloat = 2
    /// cmux's default theme pair (`GhosttyRuntime.defaultThemeSpec`).
    static let defaultThemeSpec = "light:Apple System Colors Light,dark:Apple System Colors"

    /// One look of looks.json, resolved against the checkout: its settings and each scheme's theme file text
    /// (nil: the default theme).
    struct Look {
        let id: String
        let settings: [String: JSONValue]
        let themes: [Bool: String]
        let notes: [String]
    }

    enum Skip: Error, CustomStringConvertible {
        case missing(String)
        var description: String { switch self { case let .missing(path): "missing \(path)" } }
    }

    static var repoRoot: URL { AANestedGroupsGalleryTests.repoRoot }

    static func read(_ relative: String) throws -> String {
        let url = repoRoot.appending(path: relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Skip.missing(relative) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func text(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Whether a theme file's colors are a dark scheme: its `colors` background and foreground, else its
    /// `appearance.theme`'s (the first name of a pair).
    static func isDark(themeFile text: String) throws -> Bool {
        let root = try JSONC.parse(text)
        let colors = root["colors"]
        var background = colors?["background"]?.stringValue.flatMap(ThemeRGB.init(cssHex:))
        var foreground = colors?["foreground"]?.stringValue.flatMap(ThemeRGB.init(cssHex:))
        if background == nil || foreground == nil, let spec = root["appearance.theme"]?.stringValue ?? root["appearance"]?["theme"]?.stringValue,
           let file = try? ghosttyTheme(ThemeSpec(spec)?.light ?? spec) {
            background = background ?? file.background
            foreground = foreground ?? file.foreground
        }
        guard let background, let foreground else { return false }
        return background.relativeLuminance < foreground.relativeLuminance
    }

    static func load(_ entry: JSONValue) throws -> Look {
        let id = try #require(entry["id"]?.stringValue)
        if let setup = entry["setup"]?.stringValue {
            let file = try JSONC.parse(try read("\(setup)/cmux-setup.json"))
            let settings = file["settings"]?.objectValue ?? [:]
            var themes: [Bool: String] = [:]
            var notes: [String] = []
            if let name = settings["appearance.themeFile"]?.stringValue {
                let text = try read("\(setup)/themes/\(name).json")
                let dark = try isDark(themeFile: text)
                themes[dark] = text
                notes.append("theme file \(name) is \(dark ? "dark" : "light"); \(dark ? "light" : "dark") draws the default theme")
            }
            return Look(id: id, settings: settings, themes: themes, notes: notes)
        }
        var themes: [Bool: String] = [:]
        for (key, dark) in [("light", false), ("dark", true)] {
            guard let scheme = entry["schemes"]?[key] else { continue }
            if let path = scheme["themeFile"]?.stringValue {
                themes[dark] = try read(path)
            } else if let inline = scheme["theme"] {
                themes[dark] = try text(inline)
            }
        }
        return Look(id: id, settings: entry["settings"]?.objectValue ?? [:], themes: themes, notes: [])
    }

    /// A Ghostty theme by name: cmux's own, else Ghostty's bundled ones.
    static func ghosttyTheme(_ name: String) throws -> ThemeFileColors {
        let own = "Resources/cmux-themes/\(name)"
        let text = try (try? read(own)) ?? read("Resources/ghostty/themes/\(name)")
        return try #require(ThemeFileColors(name: name, themeFile: text))
    }

    /// The look's settings with its theme file over them, as the app's config load makes them.
    static func snapshot(_ look: Look, dark: Bool, notes: inout [String]) -> CmuxConfigSnapshot {
        var root = JSONValue.object([:])
        for (key, value) in look.settings.sorted(by: { $0.key < $1.key }) where key != "appearance.themeFile" {
            root = SettingsController.replacing(CmuxConfigFile.keyPath(from: key), with: value, in: root)
        }
        if let text = look.themes[dark] {
            let overlay = ThemeFileOverlay(name: look.id, source: .success(text), base: root)
            for diagnostic in overlay.diagnostics { notes.append("theme file: \(diagnostic.path): \(diagnostic.message)") }
            root = overlay.applied(to: root)
        }
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics,
                                                configDirectory: FileManager.default.temporaryDirectory)
        for diagnostic in snapshot.diagnostics { notes.append("settings: \(diagnostic.path): \(diagnostic.message)") }
        return snapshot
    }

    /// The theme the snapshot names for the scheme, with its edits (`appearance.themeEdits`, a theme file's
    /// `colors`) and highlight over the theme's own colors, and the accent.
    static func input(_ snapshot: CmuxConfigSnapshot, dark: Bool, notes: inout [String]) throws -> (String, ThemeInput) {
        let spec = snapshot.appTheme ?? defaultThemeSpec
        var name = ThemeSpec(spec)?.name(isDark: dark) ?? spec
        let file: ThemeFileColors
        if let found = try? ghosttyTheme(name) {
            file = found
        } else {
            notes.append("theme \(name) is not in Resources: drew the default")
            name = try #require(ThemeSpec(defaultThemeSpec)).name(isDark: dark)
            file = try ghosttyTheme(name)
        }
        let edits = snapshot.themeEdits.colors[name] ?? [:]
        func edit(_ token: String) -> ThemeRGB? { edits[token].flatMap(ThemeRGB.init(cssHex:)) }
        let palette = file.palette.enumerated().compactMap { index, color in edit(String(index)) ?? color }
        var input = ThemeInput(background: edit("background") ?? file.background, foreground: edit("foreground") ?? file.foreground,
                               palette: palette, selectionBackground: edit("selection") ?? file.selectionBackground,
                               selectionForeground: file.selectionForeground)
        if let highlight = snapshot.highlightColor.flatMap(ThemeRGB.init(cssHex:)) { input.selectionBackground = highlight }
        input.cursor = edit("cursor") ?? file.cursorColor
        input.accentColor = edit("accent") ?? file.accent
        input.accent = snapshot.accent
        return (name, input)
    }

    /// Two project groups and a loose row, as a person's sidebar holds them mid-afternoon.
    static func sections(now: Date) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ago(minutes: Double = 0, days: Double = 0) -> Date { now.addingTimeInterval(-60 * minutes - 86_400 * days) }
        func chat(_ id: String, _ title: String, folder: String, branch: String, brand: String, at date: Date,
                  activity: StatusIndicatorState = .idle, unread: UnreadState = .none, message: String) -> SidebarWorkspace {
            var ws = SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: folder, branch: branch, lastActivity: date,
                                      rowKind: .agent, agentWorking: activity == .working, kind: .harness, kindBrand: brand,
                                      unread: unread, activity: activity, agentBrand: brand,
                                      agentName: brand == "codex" ? "Codex" : "Claude Code", folder: folder)
            ws.lastMessage = message
            if case .waiting = activity { ws.agentChip = .needsYou }
            return ws
        }
        let atlas = SidebarGroup(id: GroupID("g-atlas"), name: "atlas-web", color: .blue, workspaces: [
            chat("retries", "Add retries to the fetch helper", folder: "~/code/atlas-web", branch: "fetch-retries", brand: "claude",
                 at: ago(minutes: 4), message: "Retries back off 200, 400 and 800 ms; tests pass"),
            chat("flaky", "Fix the flaky checkout test", folder: "~/code/atlas-web", branch: "checkout-flake", brand: "codex",
                 at: ago(minutes: 1), activity: .working, message: "Running the checkout suite 20 times"),
            chat("router", "Move settings pages to the new router", folder: "~/code/atlas-web", branch: "router-v2", brand: "claude",
                 at: ago(days: 1), unread: .dot, message: "Done: 14 routes moved, two redirects added"),
        ])
        let billing = SidebarGroup(id: GroupID("g-billing"), name: "billing-api", color: .green, workspaces: [
            chat("refunds", "Idempotent refund webhooks", folder: "~/code/billing-api", branch: "refund-idempotency", brand: "claude",
                 at: ago(minutes: 12), activity: .waiting(kind: .permission), message: "Allow running the migration on staging?"),
            chat("invoices", "Invoice PDF page breaks", folder: "~/code/billing-api", branch: "invoice-pdf", brand: "codex",
                 at: ago(days: 3), message: "Tables no longer split across pages"),
        ])
        var shell = SidebarWorkspace(id: WorkspaceID("w-release"), title: "Release notes for 2.4", directory: "~/code/atlas-web",
                                     process: "zsh", lastActivity: ago(days: 9), kind: .terminal, folder: "~/code/atlas-web")
        shell.lastMessage = "git log v2.3..HEAD --oneline"
        return [SidebarSection(kind: .machine(machine), nodes: [.group(atlas), .group(billing), .workspace(shell)])]
    }

    static let selected = WorkspaceID("w-retries")

    /// The selected chat's tabs: the chat (selected), a working terminal, an unread browser tab and a file.
    static func tabs() -> TabStripModel {
        return TabStripModel(tabs: [
            TabItem(id: TabID("t-chat"), title: "Add retries to the fetch helper", icon: .agentMark("claude")),
            TabItem(id: TabID("t-tests"), title: "bun test --watch", icon: .symbol("terminal"), isBusy: true),
            TabItem(id: TabID("t-preview"), title: "localhost:5173", icon: .symbol("globe"), isUnread: true),
            TabItem(id: TabID("t-file"), title: "fetch.ts", icon: .symbol("doc.text")),
        ], selectedID: TabID("t-chat"))
    }

    static func render(_ look: Look, dark: Bool, notes: inout [String]) throws -> CGImage {
        _ = NSApplication.shared
        let snapshot = Self.snapshot(look, dark: dark, notes: &notes)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        let (themeName, input) = try Self.input(snapshot, dark: dark, notes: &notes)
        ThemeScope.app.store.setAccent(snapshot.accent)
        _ = ThemeScope.app.store.apply(input)
        ThemeScope.app.setSurfaceBackgrounds(snapshot.surfaceBackgrounds)
        notes.append("theme \(themeName), accent \(snapshot.accent.rawValue), density \(DesignSettings.shared.sidebarSections.density.rawValue), "
                     + "timestamps \(DesignSettings.shared.sidebarSections.showTimestamps ? "on" : "off"), surfaces "
                     + snapshot.surfaceBackgrounds.overrides.keys.map(\.rawValue).sorted().joined(separator: ","))

        let (width, height) = (size.width, size.height)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(themeName), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

        // The sidebar column: its surface (the look's sidebar color, else the sidebar's dim), then the list.
        let ground = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: height))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = scope.perform { (Palette.surfaceOverride(.sidebar) ?? SidebarStyle.surfaceDim)?.cgColor }
        root.addSubview(ground)
        let model = SidebarModel(sections: sections(now: Date()), activeWorkspaceID: selected)
        model.applyListPreferences(DesignSettings.shared.sidebarSections)
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height - 12)
        root.addSubview(list)

        // The tab strip over its pane: the pane takes the look's agent pane color, the strip its tab bar color.
        let paneX = sidebarWidth
        let stripHeight = TabStripView.preferredHeight
        let pane = NSView(frame: NSRect(x: paneX, y: 0, width: width - paneX, height: height - stripHeight))
        pane.wantsLayer = true
        pane.layer?.backgroundColor = scope.perform { Palette.surfaceOverride(.agentPane)?.cgColor }
        root.addSubview(pane)
        let strip = TabStripView(model: tabs())
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: paneX, y: height - stripHeight, width: width - paneX, height: stripHeight)
        strip.wantsLayer = true
        strip.layer?.backgroundColor = scope.perform { Palette.surfaceOverride(.tabBar)?.cgColor }
        root.addSubview(strip)

        window.orderFrontRegardless()
        strip.windowMain.changed(isMain: true)
        list.reload(animated: false)
        list.frame.origin.y = height - 12 - list.frame.height
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// Back to the defaults: no look's settings, theme or surfaces stay for the next suite.
    static func reset() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        ThemeScope.app.setSurfaceBackgrounds(.none)
        ThemeScope.app.store.setAccent(snapshot.accent)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        defer { try? Self.reset() }
        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "golden-look-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let looks = try JSONC.parse(try Self.read("webviews/src/gallery/golden/looks.json"))["looks"]?.arrayValue ?? []
        #expect(!looks.isEmpty, "looks.json lists no looks")
        var rows: [[CGImage]] = []
        var notes: [String] = []
        for entry in looks {
            let id = entry["id"]?.stringValue ?? "?"
            let look: Look
            do {
                look = try Self.load(entry)
            } catch let skip as Skip {
                notes.append("\(id): skipped, \(skip)")
                continue
            }
            notes += look.notes.map { "\(id): \($0)" }
            var row: [CGImage] = []
            for dark in [false, true] {
                var lines: [String] = []
                let image = try Self.render(look, dark: dark, notes: &lines)
                notes += lines.map { "\(id) \(dark ? "dark" : "light"): \($0)" }
                #expect(image.width == Int(Self.size.width * Self.scale) && image.height == Int(Self.size.height * Self.scale))
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(id)-\(dark ? "dark" : "light").png"))
                row.append(image)
            }
            rows.append(row)
        }
        try (notes.joined(separator: "\n") + "\n").write(to: out.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        print("golden-look-gallery:\n" + notes.joined(separator: "\n"))
        let first = try #require(rows.first?.first, "no look was drawn")
        let w = first.width, h = first.height, gap = 24
        let ctx = try #require(CGContext(data: nil, width: 2 * w + gap, height: rows.count * h + (rows.count - 1) * gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                ctx.draw(image, in: CGRect(x: c * (w + gap), y: ctx.height - (r + 1) * h - r * gap, width: w, height: h))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "golden-look-gallery.tar", "golden-look-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
