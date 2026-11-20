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
/// terminal-tinted themes, on the three grounds a control sits on (the window, a popover's card over
/// the worst desktop, and a see-through window over the worst desktop), enabled and disabled. Each
/// control's label is read from the painted pixels: its ink against its own fill must reach 4.5:1
/// for text (3:1 for an icon), and a disabled control's 2.5:1, the legible floor.
///
/// A see-through window over the worst desktop can hold less than 4.5:1 for any ink (a dark theme
/// at 60% over white is a mid gray): there the minimum is what the theme's own primary text reaches
/// on that ground, so a control fails only when it reads worse than the theme's text does. SwiftUI's
/// system bezel is read too, for the report only (`isReference`): cmux surfaces must not ship it.
///
/// With `CONTRAST_AUDIT_OUT` set the suite writes every reading as a Markdown table
/// (`native-control-contrast.md`) there; with `CMUX_CONTRAST_ALL_THEMES=1` it reads every bundled
/// theme instead of the spread.
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
        case seeThrough = "see-through window"
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
        let failures = readings.filter { !$0.passes && !$0.isReference }
        #expect(readings.count > themes.count * 6 * 10, "too few controls were read: \(readings.count)")
        var perControl: [String: Int] = [:]
        for failure in failures { perControl[failure.control + (failure.disabled ? " (disabled)" : ""), default: 0] += 1 }
        let kinds = perControl.sorted { $0.value > $1.value }.map { "\($0.value)x \($0.key)" }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) of \(readings.count) readings fail:\n"
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
        // What is behind the controls: the worst desktop for the theme under a card or a see-through window.
        let desktop: ThemeRGB = tokens.isDark ? .white : .black
        let groundColor: ThemeRGB = switch ground {
        case .window: tokens.windowBackground.withAlpha(1)
        case .popover:
            CardMaterial(tokens, lift: ChromeTunables.opaqueOverlayLift.value, minimumOpacity: ChromeTunables.cardOpacity.value)
                .tint.composited(over: desktop)
        case .seeThrough: tokens.windowBackground.composited(over: desktop)
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 360))
        container.wantsLayer = true
        container.layer?.backgroundColor = groundColor.nsColor.cgColor
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        scope.adopt(window)
        scope.root(container)
        let samples = catalog(scope: scope, disabled: disabled)
        // The most any ink reaches on a see-through ground: the theme's own primary text there.
        let ceiling = ground == .seeThrough ? tokens.textPrimary.withAlpha(1).contrast(with: groundColor) : .infinity
        var x: CGFloat = 16, y: CGFloat = 16, rowHeight: CGFloat = 0
        for sample in samples {
            container.addSubview(sample.view)
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
        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / container.bounds.width
        return samples.compactMap { sample in
            // The label sits in the middle of the control: its edges are the bezel's border and the ground.
            let frame = sample.view.frame
            let inset = frame.insetBy(dx: min(10, frame.width * 0.2), dy: frame.height * 0.22)
            let top = container.bounds.height - inset.maxY
            // A glyph's few core pixels are its color (WCAG reads a graphic's color, not its antialiased edge).
            guard let patch = Patch(rep, x: inset.minX * scale, y: top * scale, width: inset.width * scale, height: inset.height * scale,
                                    percentile: sample.isIcon ? 0.99 : 0.95)
            else { return nil }
            let standard = disabled ? disabledMinimum : sample.isIcon ? iconMinimum : textMinimum
            let minimum = min(standard, ceiling * standard / textMinimum)
            return Reading(theme: theme.label, ground: ground, control: sample.name, disabled: disabled,
                           ratio: patch.ratio, minimum: minimum, ink: patch.ink, fill: patch.fill,
                           isReference: sample.isReference)
        }
    }

    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    /// Every shared button look, as the app constructs it.
    static func catalog(scope: ThemeScope, disabled: Bool) -> [Sample] {
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
            swiftUI("SwiftUI Button (cmuxPressFill)", Button("Rename") {}.buttonStyle(.cmuxPressFill).foregroundStyle(ink)),
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

    init?(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percentile: Double) {
        let x0 = max(0, Int(x)), y0 = max(0, Int(y))
        let x1 = min(rep.pixelsWide, Int(x + width)), y1 = min(rep.pixelsHigh, Int(y + height))
        guard x1 > x0, y1 > y0 else { return nil }
        var pixels: [ThemeRGB] = []
        var buckets: [Int: (count: Int, sum: (Double, Double, Double))] = [:]
        for py in y0..<y1 {
            for px in x0..<x1 {
                guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let rgb = ThemeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
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

private extension ThemeRGB {
    /// `#rrggbb`, for the report.
    var auditHex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
