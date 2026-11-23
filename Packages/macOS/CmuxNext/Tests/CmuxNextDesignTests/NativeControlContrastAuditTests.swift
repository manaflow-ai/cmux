import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import SwiftUI
import Testing
import CmuxNextDesignTokens

/// User 2026-11-20, after the bookmark editor's More…/Remove read as nearly invisible: "we should do
/// audit of all surfaces like this to make sure all buttons have proper contrasts in all
/// themes/modes". The native half of the control contrast audit (the web half is
/// webviews/test/control-contrast-N.test.ts): every shared button look cmux draws in AppKit and
/// SwiftUI is rendered for real in an offscreen window, in a spread of light, dark and
/// terminal-tinted themes, on the grounds a control sits on (the window, a popover's opaque surface, a
/// popover's glass over its own window, over a white and over a black page, and a see-through window over
/// the worst desktop), enabled and disabled. The opaque popover is a real ``OverlaySurfaceView`` on its popup
/// surface (Reduce Transparency). The glass popover is a real menu panel
/// (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``, the bookmark bubble's and the host pressure
/// popover's surface), so each control finds the menu glass in its view tree. No glass material draws
/// offscreen, so the window paints the page under the menu's glass tint, the panel's own veil lays the theme
/// surface on it, and the suite checks that the ground reads back as the menu glass over that page. Each control fits its inks to the ground it finds in
/// the view tree, as in the app. Hot Dog Stand's gray buttons read 2.66 to 3.68:1 on its popover glass over
/// its own red window in the real app while the opaque ground passed (fixed in e03795f).
/// It was the ``CardMaterial`` fill over the worst desktop, which no native overlay draws. Each
/// control's label is read from the painted pixels: its ink against its own fill must reach 4.5:1
/// for text (3:1 for an icon), and a disabled control's 2.5:1, the legible floor.
///
/// A see-through window over the worst desktop can hold less than 4.5:1 for any ink (a dark theme
/// at 60% over white is a mid gray): there the minimum is what the theme's own primary text reaches
/// on that ground, so a control fails only when it reads worse than the theme's text does. SwiftUI's
/// system bezel is read too, for the report only (`isReference`): cmux surfaces must not ship it.
///
/// `Tests/Fixtures/native-control-contrast-baseline.txt` is a ratchet of known violations waiting on a
/// fix, one line per control and state (`<control> | <enabled|disabled> | <floor>`): a failing reading
/// of a listed control passes while it reads at least its floor; a new failing control, or a listed one
/// that gets worse, fails the suite. Each run prints its worst reading per control as baseline lines.
///
/// With `CONTRAST_AUDIT_OUT` set the suite writes every reading as a Markdown table
/// (`native-control-contrast.md`) there; with `CMUX_CONTRAST_ALL_THEMES=1` it reads every bundled
/// theme instead of the spread. Each run prints the three worst readings of every failing control.
@MainActor @Suite(.serialized, .closesItsWindows) struct NativeControlContrastAuditTests {
    /// The spread: the default pair, the high-chroma and mid-tone themes that broke chrome before
    /// (Hot Dog Stand, Grass, Blue Dolphin), and common light and dark terminal themes.
    static let spread = [
        "Apple System Colors", "Apple System Colors Light", "Rose Pine Dawn", "Catppuccin Mocha", "Hot Dog Stand",
        "Grass", "Blue Dolphin", "Solarized Dark Higher Contrast", "Gruvbox Light", "Nord", "Nord Light", "Dracula",
        "GitHub Light Default", "Man Page", "Red Planet", "Builtin Tango Light",
    ]

    /// A ground a control is drawn on.
    enum Ground: String, CaseIterable {
        case window
        case popover
        case glassOverWindow = "popover glass over its window"
        case glassOverWhite = "popover glass over a white page"
        case glassOverBlack = "popover glass over a black page"
        case seeThrough = "see-through window"

        /// The page under a glass popover in `tokens`' theme; nil for a ground with no glass.
        func page(_ tokens: ThemeTokens) -> ThemeRGB? {
            switch self {
            case .glassOverWindow: tokens.windowBackground.withAlpha(1)
            case .glassOverWhite: .white
            case .glassOverBlack: .black
            case .window, .popover, .seeThrough: nil
            }
        }

        var isGlass: Bool { self == .glassOverWindow || self == .glassOverWhite || self == .glassOverBlack }
    }

    /// One control as the audit draws it.
    struct Sample {
        let name: String
        let view: NSView
        let isIcon: Bool
        /// Drawn for the report only: SwiftUI's system bezel, which cmux surfaces must not ship.
        var isReference = false
    }

    /// One reading: the control's ink on its own fill.
    struct Reading {
        let theme: String
        let ground: Ground
        let control: String
        let disabled: Bool
        let ratio: Double
        let minimum: Double
        let ink: ThemeRGB
        let fill: ThemeRGB
        var isReference = false
        var passes: Bool { ratio + 0.005 >= minimum }
        /// The baseline key: `<control> | <enabled|disabled>`.
        var key: String { "\(control) | \(disabled ? "disabled" : "enabled")" }
    }

    /// The known failures: each ``Reading/key`` with its floor (`#` starts a comment).
    static func baseline() throws -> [String: Double] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/native-control-contrast-baseline.txt")
        let text = try String(contentsOf: file, encoding: .utf8)
        var floors: [String: Double] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.components(separatedBy: " | ")
            let floor = try #require(fields.count == 3 ? Double(fields[2]) : nil, "baseline line without a floor: \(line)")
            floors[fields[0] + " | " + fields[1]] = floor
        }
        return floors
    }

    static let textMinimum = 4.5, iconMinimum = 3.0, disabledMinimum = 2.5

    @Test func everySharedControlReadsOnEveryGroundInEveryTheme() throws {
        _ = NSApplication.shared
        let all = ProcessInfo.processInfo.environment["CMUX_CONTRAST_ALL_THEMES"] == "1"
        let themes = try CardNeverOpaqueTests.bundledThemes().filter { all || Self.spread.contains($0.name) }
        #expect(all || themes.count == Self.spread.count, "a theme of the spread is no longer bundled")
        var readings: [Reading] = []
        for theme in themes {
            for ground in Ground.allCases {
                for disabled in [false, true] {
                    readings += try Self.read(theme, ground: ground, disabled: disabled)
                }
            }
        }
        if let out = ProcessInfo.processInfo.environment["CONTRAST_AUDIT_OUT"] { try Self.report(readings, to: out) }
        let known = try Self.baseline()
        let failing = readings.filter { !$0.passes && !$0.isReference }
        var worst: [String: Double] = [:]
        for reading in failing { worst[reading.key] = min(worst[reading.key] ?? .infinity, reading.ratio) }
        for (key, floor) in worst.sorted(by: { $0.key < $1.key }) {
            print(String(format: "native-control-contrast baseline: %@ | %.2f", key, (floor * 100).rounded(.down) / 100))
        }
        for key in Set(known.keys).subtracting(worst.keys).sorted() where !all {
            print("native-control-contrast: baseline line no longer found, drop it: \(key)")
        }
        // The three worst readings of each failing control and state, to show where a fix is owed.
        for (_, group) in Dictionary(grouping: failing, by: \.key).sorted(by: { $0.key < $1.key }) {
            for reading in group.sorted(by: { $0.ratio < $1.ratio }).prefix(3) {
                print("native-control-contrast failing: " + Self.line(reading))
            }
        }
        let failures = failing.filter { $0.ratio + 0.005 < (known[$0.key] ?? .infinity) }
        #expect(readings.count > themes.count * Ground.allCases.count * 2 * 10, "too few controls were read: \(readings.count)")
        var perControl: [String: Int] = [:]
        for failure in failures { perControl[failure.control + (failure.disabled ? " (disabled)" : ""), default: 0] += 1 }
        let kinds = perControl.sorted { $0.value > $1.value }.map { "\($0.value)x \($0.key)" }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) of \(readings.count) readings fail, not in the baseline:\n"
            + kinds.joined(separator: "\n") + "\nfirst:\n" + failures.prefix(40).map(Self.line).joined(separator: "\n")))
    }

    static func line(_ r: Reading) -> String {
        String(format: "%@ on %@: %@%@ %.2f:1 < %.1f:1, ink %@ on %@", r.theme, r.ground.rawValue,
               r.control, r.disabled ? " disabled" : "", r.ratio, r.minimum, r.ink.auditHex, r.fill.auditHex)
    }

    // MARK: Drawing

    /// Draws every control of the catalog in `theme` on `ground` and reads each one.
    static func read(_ theme: CardNeverOpaqueTests.BundledTheme, ground: Ground, disabled: Bool) throws -> [Reading] {
        var input = theme.input
        if ground == .seeThrough { input.backgroundOpacity = 0.6 }
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Audit \(theme.name)")), input: input, animated: false)
        let tokens = scope.tokens
        // What is behind a see-through window: the worst desktop for the theme.
        let desktop: ThemeRGB = tokens.isDark ? .white : .black
        let groundColor: ThemeRGB = switch ground {
        case .window: tokens.windowBackground.withAlpha(1)
        case .popover: tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
        case .glassOverWindow, .glassOverWhite, .glassOverBlack: menuGlass(tokens, over: ground.page(tokens) ?? .white)
        case .seeThrough: tokens.windowBackground.composited(over: desktop)
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 360))
        container.wantsLayer = true
        // Under glass the window paints only the page: the panel's own tint view and veil (``GlassMenuVeilView``) lay
        // the theme's menu glass on it, as in the app.
        container.layer?.backgroundColor = (ground.page(tokens) ?? groundColor).nsColor.cgColor
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The capture is read as sRGB: a window in the screen's space shifts the danger fill
        // #d93b31, which misread white on it as 4.16:1.
        window.colorSpace = .sRGB
        window.contentView = container
        defer { window.close() }
        scope.adopt(window)
        scope.root(container)
        // On a popover the controls sit in a real overlay surface, which paints the ground itself.
        var host: NSView = container
        if ground == .popover {
            let surface = OverlaySurfaceView(material: .opaque, interactive: true, cornerRadius: 0)
            surface.frame = container.bounds
            container.addSubview(surface)
            host = surface.contentView
        } else if ground.isGlass {
            let surface = Glass.makeMenuPanel(interactive: true)
            surface.materialOverride = .vibrancy
            // A menu panel is laid out by its owner's constraints; with none here it sized to zero, and drew nothing.
            surface.translatesAutoresizingMaskIntoConstraints = true
            surface.autoresizingMask = [.width, .height]
            surface.frame = container.bounds
            container.addSubview(surface)
            // No glass material draws offscreen: Liquid Glass drew the panel black, and the blur (an
            // NSVisualEffectView) drew nothing, with its tint, veil and controls. The panel's tint view (the theme's
            // menu tint, holding the veil and the controls) moves out of the blur onto the panel, so each control
            // still finds the menu glass above it (``NSView/buttonGround(_:)``) and fits its inks to it, as in the
            // app; only the blur is hidden.
            let blur = try #require(surface.subviews.first { $0 is NSVisualEffectView })
            let tint = try #require(surface.contentView.superview)
            #expect(tint !== blur && tint.isDescendant(of: blur), "the menu panel's content is not in its tint view")
            tint.removeFromSuperview()
            tint.frame = surface.bounds
            tint.autoresizingMask = [.width, .height]
            surface.addSubview(tint, positioned: .above, relativeTo: blur)
            blur.isHidden = true
            #expect(surface.material == .vibrancy && !surface.drawsNoMaterial && surface.tintLevel == .menu)
            host = surface.contentView
        }
        // A swatch of a known color: the capture must give it back, or no reading of it can be trusted.
        let swatchColor = ThemeRGB(red: 0xd9 / 255.0, green: 0x3b / 255.0, blue: 0x31 / 255.0)
        let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = swatchColor.nsColor.cgColor
        container.addSubview(swatch)
        let samples = catalog(scope: scope, disabled: disabled, onMenuGlass: ground.isGlass)
        // The most any ink reaches on a see-through ground: the theme's own primary text there.
        // Read as the capture holds them, 8 bits a channel: Rose Pine Dawn's text is 2.363:1 on its exact ground and
        // 2.354:1 on the 8-bit one, so the theme's own ink failed its own ceiling.
        let ceiling = ground == .seeThrough ? tokens.textPrimary.withAlpha(1).eightBit.contrast(with: groundColor.eightBit) : .infinity
        var x: CGFloat = 16, y: CGFloat = 16, rowHeight: CGFloat = 0
        for sample in samples {
            host.addSubview(sample.view)
            let size = sample.view.fittingSize
            let width = max(size.width, 24), height = max(size.height, 22)
            if x + width > container.bounds.width - 16 { x = 16; y += rowHeight + 16; rowHeight = 0 }
            sample.view.frame = NSRect(x: x, y: container.bounds.height - y - height, width: width, height: height)
            x += width + 16
            rowHeight = max(rowHeight, height)
        }
        scope.root(container)
        container.layoutSubtreeIfNeeded()
        for view in allViews(container) { view.viewDidChangeEffectiveAppearance(); view.needsDisplay = true }
        container.layoutSubtreeIfNeeded()
        // The veil was added to the panel's content while it had no size, and draws in updateLayer, which
        // cacheDisplay does not run: it takes its content's bounds and draws now.
        for view in allViews(container) where view is GlassMenuVeilView {
            view.frame = view.superview?.bounds ?? view.frame
            view.updateLayer()
        }
        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / container.bounds.width
        // A headless Mac tags the capture with a generic RGB profile while its bytes hold the sRGB
        // values (#d93b31 then converts to #e3523f, as if gamma 1.8): read each pixel both through
        // the tag and as raw sRGB samples, and keep the read that gives the swatch back.
        let swatchAt = (x: Int(4 * scale), y: rep.pixelsHigh - Int(4 * scale))
        let reads = PixelRead.allCases.compactMap { read in
            read.color(rep, x: swatchAt.x, y: swatchAt.y).map { (read: read, drift: $0.drift(from: swatchColor)) }
        }
        let best = try #require(reads.min { $0.drift < $1.drift })
        let read = best.read
        // Under glass, an empty corner of the panel must read back as the menu glass over the page, or the
        // controls were not drawn on the ground the audit names.
        if ground.isGlass {
            let empty = try #require(read.color(rep, x: Int((container.bounds.width - 40) * scale), y: rep.pixelsHigh - Int(40 * scale)))
            print("native-control-contrast glass: \(theme.name) \(ground.rawValue)\(disabled ? " disabled" : ""): corner "
                + "\(empty.auditHex), model \(groundColor.auditHex), \(samples.count) samples")
            #expect(empty.drift(from: groundColor) < 3 / 255, Comment(rawValue: "\(theme.name) \(ground.rawValue): the ground read "
                + "\(empty.auditHex), the menu glass is \(groundColor.auditHex)"))
        }
        #expect(best.drift < 2.5 / 255, Comment(rawValue: "the capture shifts colors: #d93b31 read back as "
            + reads.map { "\($0.read): \($0.read.color(rep, x: swatchAt.x, y: swatchAt.y)?.auditHex ?? "-")" }.joined(separator: ", ")
            + " (rep \(rep.colorSpace.localizedName ?? rep.colorSpaceName.rawValue), \(rep.bitsPerSample) bits, format \(rep.bitmapFormat.rawValue))"))
        return samples.compactMap { sample in
            // The label sits in the middle of the control: its edges are the bezel's border and the ground.
            let frame = sample.view.frame
            let inset = frame.insetBy(dx: min(10, frame.width * 0.2), dy: frame.height * 0.22)
            let top = container.bounds.height - inset.maxY
            // A glyph's few core pixels are its color (WCAG reads a graphic's color, not its antialiased edge).
            guard let patch = Patch(rep, read: read, x: inset.minX * scale, y: top * scale, width: inset.width * scale, height: inset.height * scale,
                                    percentile: sample.isIcon ? 0.99 : 0.95)
            else { return nil }
            let standard = disabled ? disabledMinimum : sample.isIcon ? iconMinimum : textMinimum
            // Under a see-through ceiling the theme's own text is the best any ink can do; its antialiased edge pulls the
            // patch's percentile a hair under the ink itself (Dracula's text read 3.73:1 against a 3.75:1 ceiling).
            let minimum = min(standard, ceiling * standard / textMinimum - (ceiling < textMinimum ? 0.05 : 0))
            return Reading(theme: theme.label, ground: ground, control: sample.name, disabled: disabled,
                           ratio: patch.ratio, minimum: minimum, ink: patch.ink, fill: patch.fill,
                           isReference: sample.isReference)
        }
    }

    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    /// A menu panel's glass over `page`: the tint, then the theme's veil (``GlassMenuMaterial/veil(for:)``).
    static func menuGlass(_ tokens: ThemeTokens, over page: ThemeRGB) -> ThemeRGB {
        GlassMenuMaterial.glass(tokens, veil: GlassMenuMaterial.veil(for: tokens), over: page)
    }

    /// Every shared button look, as the app constructs it: SwiftUI content a menu panel hosts is marked as on its glass
    /// (`cmuxOnMenuGlass`), as the Downloads popup marks its own.
    static func catalog(scope: ThemeScope, disabled: Bool, onMenuGlass: Bool = false) -> [Sample] {
        let enabled = !disabled
        func appKit(_ name: String, _ button: NSControl, icon: Bool = false) -> Sample {
            button.isEnabled = enabled
            return Sample(name: name, view: button, isIcon: icon)
        }
        func swiftUI(_ name: String, _ view: some View, reference: Bool = false) -> Sample {
            let host = NSHostingView(rootView: AnyView(view.disabled(disabled)))
            host.sizingOptions = [.intrinsicContentSize]
            return Sample(name: name, view: host, isIcon: false, isReference: reference)
        }
        let selection = scope.perform { Color(nsColor: Palette.selectionFill) }
        let ink = scope.perform { Color(nsColor: Palette.textPrimary) }
        let bezel = ThemedBezelButton(frame: .zero)
        bezel.title = "Remove"
        bezel.bezelStyle = .push
        let defaultButton = ThemedDefaultButton(frame: .zero)
        defaultButton.title = "Done"
        defaultButton.bezelStyle = .push
        defaultButton.keyHint = .return
        let checkbox = ThemedCheckbox(checkboxWithTitle: "Show bookmarks bar", target: nil, action: nil)
        let popup = ThemedPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "Bookmarks Bar")
        return [
            appKit("ThemedBezelButton", bezel),
            appKit("ThemedDefaultButton", defaultButton),
            appKit("ThemedCheckbox", checkbox),
            appKit("ThemedPopUpButton", popup),
            appKit("CmuxDialogButtonView default", CmuxDialogButtonView(standalone: .ok("Save"), target: nil, action: NSSelectorFromString("noop:"))),
            appKit("CmuxDialogButtonView cancel", CmuxDialogButtonView(standalone: .cancel("Cancel"), target: nil, action: NSSelectorFromString("noop:"))),
            appKit("CmuxDialogButtonView destructive", CmuxDialogButtonView(
                standalone: CmuxDialogButton(id: "delete", title: "Delete", role: .destructive), target: nil, action: NSSelectorFromString("noop:"))),
            appKit("CmuxDialogButtonView normal", CmuxDialogButtonView(
                standalone: CmuxDialogButton(id: "more", title: "More…", role: .normal), target: nil, action: NSSelectorFromString("noop:"))),
            appKit("PlusButton", PlusButton(label: "New Tab"), icon: true),
            appKit("OverflowButton", OverflowButton(label: "More"), icon: true),
            appKit("TitlebarBandButton", TitlebarBandButton(symbol: "sidebar.left"), icon: true),
            appKit("SignInButton", SignInButton(onSignIn: {})),
            // The bookmark bubble's shape: SwiftUI's default button in a themed popover, tinted with the selection.
            swiftUI("system bezel: SwiftUI Button, selection tint", Button("More…") {}.tint(selection), reference: true),
            swiftUI("system bezel: SwiftUI Button", Button("Remove") {}, reference: true),
            swiftUI("CmuxDialogActionButton (selection tint)", CmuxDialogActionButton("Done", hint: .return) {}.tint(selection)),
            swiftUI("SwiftUI Button (cmuxPressFill)", Button("Rename") {}.buttonStyle(.cmuxPressFill).foregroundStyle(ink)
                .cmuxOnMenuGlass(onMenuGlass ? scope.tokens : nil)),
        ]
    }

    // MARK: Report

    static func report(_ readings: [Reading], to directory: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let failing = readings.filter { !$0.passes }.sorted { $0.ratio / $0.minimum < $1.ratio / $1.minimum }
        var lines = [
            "# Native control contrast", "",
            "\(readings.count) readings, \(failing.count) under their minimum.", "",
            "| theme | ground | control | state | measured | minimum | ink on fill |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for r in failing {
            lines.append(String(format: "| %@ | %@ | %@ | %@ | %.2f:1 | %.1f:1 | %@ on %@ |", r.theme, r.ground.rawValue, r.control,
                                r.disabled ? "disabled" : "enabled", r.ratio, r.minimum, r.ink.auditHex, r.fill.auditHex))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url.appending(path: "native-control-contrast.md"), atomically: true, encoding: .utf8)
    }
}

/// The ink of one painted patch against its fill: the fill is the patch's most common color, the ink
/// the given percentile of the other pixels' contrast with it (antialiased edges sit below it).
private struct Patch {
    let fill: ThemeRGB
    let ink: ThemeRGB
    let ratio: Double

    init?(_ rep: NSBitmapImageRep, read: PixelRead, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percentile: Double) {
        let x0 = max(0, Int(x)), y0 = max(0, Int(y))
        let x1 = min(rep.pixelsWide, Int(x + width)), y1 = min(rep.pixelsHigh, Int(y + height))
        guard x1 > x0, y1 > y0 else { return nil }
        var pixels: [ThemeRGB] = []
        var buckets: [Int: (count: Int, sum: (Double, Double, Double))] = [:]
        for py in y0..<y1 {
            for px in x0..<x1 {
                guard let rgb = read.color(rep, x: px, y: py) else { continue }
                pixels.append(rgb)
                let key = Int(rgb.red * 31) << 10 | Int(rgb.green * 31) << 5 | Int(rgb.blue * 31)
                let old = buckets[key] ?? (0, (0, 0, 0))
                buckets[key] = (old.count + 1, (old.sum.0 + rgb.red, old.sum.1 + rgb.green, old.sum.2 + rgb.blue))
            }
        }
        guard let mode = buckets.max(by: { $0.value.count < $1.value.count })?.value else { return nil }
        let n = Double(mode.count)
        let fill = ThemeRGB(red: mode.sum.0 / n, green: mode.sum.1 / n, blue: mode.sum.2 / n)
        let inks = pixels.map { ($0, $0.contrast(with: fill)) }.filter { $0.1 > 1.1 }.sorted { $0.1 < $1.1 }
        guard inks.count >= 10 else { return nil }
        let at = inks[Int(percentile * Double(inks.count - 1))]
        self.fill = fill
        ink = at.0
        ratio = at.1
    }
}

/// How a captured pixel is read as sRGB: through the capture's color space tag, or as its raw samples.
private enum PixelRead: CaseIterable, CustomStringConvertible {
    case tagged
    case rawSamples

    var description: String { self == .tagged ? "tagged" : "raw" }

    func color(_ rep: NSBitmapImageRep, x: Int, y: Int) -> ThemeRGB? {
        switch self {
        case .tagged:
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return ThemeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        case .rawSamples:
            guard rep.bitsPerSample == 8, rep.samplesPerPixel >= 3, !rep.bitmapFormat.contains(.floatingPointSamples) else { return nil }
            var samples = [Int](repeating: 0, count: rep.samplesPerPixel)
            rep.getPixel(&samples, atX: x, y: y)
            let first = rep.hasAlpha && rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            return ThemeRGB(red: Double(samples[first]) / 255, green: Double(samples[first + 1]) / 255,
                            blue: Double(samples[first + 2]) / 255)
        }
    }
}

private extension ThemeRGB {
    /// The largest channel difference from `other`.
    func drift(from other: ThemeRGB) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }

    /// `#rrggbb`, for the report.
    var auditHex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

private extension ThemeRGB {
    /// The color as an 8-bit capture holds it.
    var eightBit: ThemeRGB {
        func channel(_ value: Double) -> Double { (value * 255).rounded() / 255 }
        return ThemeRGB(red: channel(red), green: channel(green), blue: channel(blue), alpha: alpha)
    }
}
