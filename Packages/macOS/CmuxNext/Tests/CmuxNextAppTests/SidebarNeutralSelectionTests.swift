import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextSettings
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// `appearance.selection` (a look sets it): "neutral" keeps the selected sidebar row a gray card
/// under a theme accent, as the Codex desktop app draws its sidebar (a blue accent, a gray selected
/// row); "accent", the default, draws exactly what the accent drew before. With
/// CMUX_SIDEBAR_SELECTION_GALLERY (a folder) the gallery test renders each theme with accent and
/// neutral selection side by side to sidebar-neutral-selection.png there.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarNeutralSelectionTests {
    /// A Codex-like dark theme: a #181818 page and the bright blue accent.
    static let codexDark: ThemeInput = {
        var input = ThemeInput(background: ThemeRGB(hex: 0x181818), foreground: ThemeRGB(hex: 0xF5F5F5),
                               palette: ThemeInput.ghosttyDefault.palette)
        input.accentColor = ThemeRGB(hex: 0x339CFF)
        return input
    }()

    static func input(_ name: String) throws -> ThemeInput {
        name == "Codex Dark" ? codexDark : try SidebarSelectionLookTests.input(name)
    }

    nonisolated static let themes = ["Codex Dark", "Soft Blue", "Clay Orange Light"]

    @Test(arguments: themes) func neutralKeepsTheGrayCardUnderAnAccent(_ name: String) throws {
        var input = try Self.input(name)
        let tinted = ThemeTokens.derive(from: input)
        input.selection = .neutral
        let gray = ThemeTokens.derive(from: input)
        input.accentColor = nil
        let plain = ThemeTokens.derive(from: input)
        #expect(gray.selectionFill == plain.selectionFill, "\(name): the neutral fill")
        #expect(gray.secondarySelectionFill == plain.secondarySelectionFill)
        #expect(gray.selectionFill != tinted.selectionFill, "\(name): the accent no longer tints it")
        // Only the selection changes: the accent still marks focus and Send.
        #expect(gray.accent == tinted.accent && gray.focusRing == tinted.focusRing && gray.highlight == tinted.highlight)
    }

    @Test func accentIsTheDefaultAndDrawsAsBefore() throws {
        let input = try Self.input("Codex Dark")
        #expect(input.selection == .accent)
        var explicit = input
        explicit.selection = .accent
        #expect(ThemeTokens.derive(from: explicit) == ThemeTokens.derive(from: input))
    }

    @Test func theSettingParsesAndIsAgentSettable() throws {
        func parsed(_ value: CmuxNextSettings.JSONValue?) -> CmuxConfigSnapshot {
            let appearance: [String: CmuxNextSettings.JSONValue] = value.map { ["selection": $0] } ?? [:]
            return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
        }
        #expect(parsed(nil).selection == .accent)
        #expect(parsed(.string("neutral")).selection == .neutral)
        let bad = parsed(.string("gray"))
        #expect(bad.selection == .accent)
        #expect(bad.diagnostics.contains { $0.path == "appearance.selection" })
        #expect(SettingsSchema.descriptor(for: ["appearance", "selection"]) != nil)
    }

    /// The store's setting reaches a themed sidebar's selected row through its scope.
    @Test func theStoreSettingReachesTheSidebarScope() throws {
        let store = ThemeScope.app.store
        let (original, originalSelection) = (store.input, store.selection)
        defer { store.setSelection(originalSelection); _ = store.apply(original) }
        let (_, window, _) = try Self.sidebar("Codex Dark", selection: .neutral)
        defer { window.close() }
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Codex Dark"), input: Self.codexDark, animated: false)
        var expected = Self.codexDark
        expected.accentColor = nil
        #expect(scope.tokens.selectionFill == ThemeTokens.derive(from: expected).selectionFill)
    }

    static func sidebar(_ name: String, selection: ThemeSelection) throws -> (SidebarListView, NSWindow, [WorkspaceID]) {
        _ = NSApplication.shared
        ThemeScope.app.store.setSelection(selection)
        let ids = (1...4).map { WorkspaceID("ws-\($0)") }
        let titles = ["Change background color", "Enable worktrees", "Rename UUID creator tool", "Update main page colors"]
        let workspaces = ids.enumerated().map { SidebarWorkspace(id: $0.element, title: titles[$0.offset]) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 170), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 170))
        root.wantsLayer = true
        window.contentView = root
        _ = ThemeScope.app.store.apply(try input(name))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: try input(name), animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        model.click(ids[0])
        list.reload(animated: false)
        return (list, window, ids)
    }

    /// Each theme: the selected row with `accent` (left) and `neutral` (right). Writes to
    /// CMUX_SIDEBAR_SELECTION_GALLERY, else on the fleet's drawing opt-in (`CMUX_TEST_REQUIRE_GUI`) to
    /// `sidebar-neutral-selection.png` in the package, for `cmux-ci run --artifact`.
    @Test func galleryOfNeutralSelection() throws {
        let env = ProcessInfo.processInfo.environment
        let packageRoot = SidebarSelectionLookTests.repoRoot.appending(path: "Packages/macOS/CmuxNext").path
        guard let out = env["CMUX_SIDEBAR_SELECTION_GALLERY"] ?? (env["CMUX_TEST_REQUIRE_GUI"] == "1" ? packageRoot : nil) else { return }
        let store = ThemeScope.app.store
        let (original, originalSelection) = (store.input, store.selection)
        defer { store.setSelection(originalSelection); _ = store.apply(original) }
        var shots: [(CGImage, CGImage)] = []
        for name in Self.themes {
            var pair: [CGImage] = []
            for selection in ThemeSelection.allCases {
                let (_, window, _) = try Self.sidebar(name, selection: selection)
                defer { window.close() }
                pair.append(try #require(SidebarSelectionLookTests.snapshot(window.contentView!)))
            }
            shots.append((pair[0], pair[1]))
        }
        let w = shots[0].0.width, h = shots[0].0.height, gap = 8
        let ctx = try #require(CGContext(data: nil, width: (w + gap) * 2, height: (h + gap) * shots.count, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, pair) in shots.enumerated() {
            let y = ctx.height - (index + 1) * (h + gap)
            ctx.draw(pair.0, in: CGRect(x: 0, y: y, width: w, height: h))
            ctx.draw(pair.1, in: CGRect(x: w + gap, y: y, width: w, height: h))
        }
        let image = try #require(ctx.makeImage())
        let url = URL(fileURLWithPath: out).appending(path: "sidebar-neutral-selection.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
