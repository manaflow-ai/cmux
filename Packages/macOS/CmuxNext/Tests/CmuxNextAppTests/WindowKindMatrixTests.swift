import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Every window kind x every shortcut (plans/cmux-next/windows.md): an
/// explicit row per kind, so a new kind fails here until its row exists;
/// every kind shows a close button above its content, renders through
/// `debug.window_snapshot`, and paints the one surface token.
@MainActor
@Suite(.serialized)
struct WindowKindMatrixTests {
    /// What a kind's row says about shortcuts.
    enum Row {
        /// Everything runs (main windows).
        case runsEverything
        /// A window of its own: close actions close it, app-level actions
        /// run, destructive content actions are off, the rest run on the
        /// last main window.
        case ownWindow
    }

    /// One row per kind. Adding a kind without a row fails
    /// `everyKindHasARow`.
    static let rows: [WindowKind: Row] = [
        .main: .runsEverything,
        .settings: .ownWindow,
        .debugSettings: .ownWindow,
        .appStore: .ownWindow,
        .onboarding: .ownWindow,
        .onboardingGallery: .ownWindow,
        .browserPopup: .ownWindow,
        .devTools: .ownWindow,
        .pageInfo: .ownWindow,
        .terminalDebug: .ownWindow,
        .browserDebug: .ownWindow,
    ]

    @Test func everyKindHasARow() {
        #expect(Set(Self.rows.keys) == Set(WindowKind.allCases))
    }

    /// The behavior a row expects for one catalog action, written from the
    /// catalog's own data (ids, destructiveness, targets), not the table.
    private static func expected(_ row: Row, _ descriptor: ActionDescriptor) -> WindowKeyBehavior {
        switch row {
        case .runsEverything:
            return .run
        case .ownWindow:
            let last = descriptor.id.rawValue.split(separator: ".").last.map(String.init) ?? ""
            if last.hasPrefix("close") { return .closeWindow }
            if ["quit", "quitKeepSessions", "quitEndSessions", "quitEndEverything", "newWindow", "newIncognitoWindow",
                "openSettings", "openDebugSettings", "commandPalette", "showHideAllWindows", "about",
                "appStore.show"].contains(descriptor.id.rawValue) { return .run }
            let content: Set<ActionTargetKind> = [.tab, .pane, .workspace, .workspaceGroup, .screen, .screenGroup, .tabGroup, .column, .window]
            if descriptor.isDestructive && !content.isDisjoint(with: descriptor.targets) {
                return .disabled(reason: MiscHandlerStrings.noPane)
            }
            return .run
        }
    }

    @Test func everyKindTimesEveryDefaultShortcut() throws {
        let registry = ActionRegistry.standard()
        let table = WindowKeyTable(registry: registry)
        let shortcuts = registry.descriptors.filter { $0.defaultShortcut != nil || $0.defaultChord != nil }
        #expect(shortcuts.count > 20)
        for kind in WindowKind.allCases {
            let row = try #require(Self.rows[kind])
            for descriptor in shortcuts {
                #expect(table.behavior(for: descriptor.id, in: kind) == Self.expected(row, descriptor), "\(kind) \(descriptor.id)")
            }
        }
        // Spot checks that pin the rows to the bug reports.
        #expect(table.behavior(for: "closeTab", in: .debugSettings) == .closeWindow)
        #expect(table.behavior(for: "closeTab", in: .browserPopup) == .closeWindow)
        #expect(table.behavior(for: "closeTab", in: .main) == .run)
        #expect(table.behavior(for: "openSettings", in: .settings) == .run)
    }

    /// The raw RGBA of a pixel, 0...1. `cacheDisplay` writes the drawn
    /// sRGB values into a device RGB buffer, so converting the bitmap's
    /// color (`colorAt` + `usingColorSpace(.sRGB)`) shifts it by a gamma
    /// step; the raw bytes are what was drawn.
    static func pixel(_ rep: NSBitmapImageRep, fromBottomRight inset: Int) -> [Double] {
        var raw = [Int](repeating: 0, count: max(rep.samplesPerPixel, 4))
        rep.getPixel(&raw, atX: rep.pixelsWide - inset, y: rep.pixelsHigh - inset)
        let scale = Double((1 << rep.bitsPerSample) - 1)
        return raw.prefix(rep.samplesPerPixel).map { Double($0) / scale }
    }

    /// Whether `pixel` is `token` (sRGB components) within 2%.
    static func matches(_ pixel: [Double], _ token: ThemeRGB) -> Bool {
        pixel.count >= 3 && abs(pixel[0] - token.red) < 0.02 && abs(pixel[1] - token.green) < 0.02
            && abs(pixel[2] - token.blue) < 0.02
    }

    private func installed(_ kind: WindowKind) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 480, height: 320),
                              styleMask: [.resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.install(kind: kind, content: NSView(), scope: .app)
        return window
    }

    /// Each kind through the window kit: a visible close button above the
    /// content, a `debug.window_snapshot` PNG, and a background pixel equal
    /// to the surface token (clear for onboarding, whose steps draw glass).
    @Test func everyKindShowsACloseButtonAndSnapshotsItsSurface() throws {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-kinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = ThemeScope.app.tokens.surfaceBackground
        for kind in WindowKind.allCases where kind != .main {
            let window = installed(kind)
            SecondaryWindowCloseButtonTests.expectCloseButton(window, kind.rawValue)
            let path = directory.appending(path: "\(kind.rawValue).png").path
            let result = DebugWindowSnapshot.capture(["window": .string(String(window.windowNumber)), "path": .string(path)],
                                                     services: services)
            #expect(result["kind"]?.stringValue == kind.rawValue, "\(kind): \(result)")
            let data = try #require(FileManager.default.contents(atPath: path), "\(kind): no PNG")
            #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(kind): not a PNG")
            let rep = try #require(NSBitmapImageRep(data: data))
            // Bottom-right, inside the content: the window background.
            let pixel = Self.pixel(rep, fromBottomRight: 40)
            if kind.traits.surface == .clear {
                #expect(pixel.count == 4 && pixel[3] < 0.05, "\(kind): \(pixel)")
            } else {
                #expect(Self.matches(pixel, token), "\(kind): \(pixel) vs \(token)")
            }
            window.close()
        }
    }

    /// The main window: a real `WindowController` window, installed as
    /// `.main`, with its close button and a snapshot whose content area is
    /// the surface token.
    @Test func theMainWindowIsKindMainAndPaintsTheToken() async throws {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let controller = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        let window = try #require(controller.window)
        #expect(window.windowKind == .main)
        #expect(DebugWindowSnapshot.kind(of: window, services: services) == "main")
        SecondaryWindowCloseButtonTests.expectCloseButton(window, "main")
        let rep = try #require(window.renderSnapshot())
        let token = try #require(window.contentView?.themeTokens.surfaceBackground)
        let pixel = Self.pixel(rep, fromBottomRight: 40)
        #expect(Self.matches(pixel, token), "main: \(pixel) vs \(token)")
    }
}
