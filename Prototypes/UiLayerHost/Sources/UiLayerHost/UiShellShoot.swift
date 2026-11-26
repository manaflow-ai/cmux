import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSidebar
import CmuxNextTabs
import Foundation

// The UI shell's one-shot mode (Leo, ask-8bdd370f5f: "literally the shell, like you literally just ship the shell"):
// `cmux-ui-layer --shoot DIR [--scene a,b] [--themes DIR]` opens the real modules' playground windows, the same ones
// the app's Debug menu opens, draws each into a PNG with cacheDisplay (no Screen Recording permission), writes
// DIR/receipt.json with each scene's time, and exits. It links only the leaf UI modules (CmuxNextUiShellModules),
// never the app composition root, the daemon, Ghostty or Chromium, so a changed UI file costs a leaf rebuild.

/// `--shoot`, `--scene` and `--themes`.
struct UiShellShootOptions: Equatable {
    var output: URL
    /// Scene names to shoot; empty shoots every scene.
    var scenes: [String] = []
    /// The theme folder the playgrounds read (the repo's Resources/cmux-themes by default).
    var themes: URL

    /// The options when `--shoot DIR` is given, nil otherwise.
    static func parse(arguments: [String], defaultThemes: URL = UiShellShoot.repoThemes) -> Self? {
        var output: URL?
        var scenes: [String] = []
        var themes = defaultThemes
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch (arguments[index], value) {
            case ("--shoot", let value?):
                output = URL(fileURLWithPath: value)
                index += 2
            case ("--scene", let value?):
                scenes = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                index += 2
            case ("--themes", let value?):
                themes = URL(fileURLWithPath: value)
                index += 2
            default:
                index += 1
            }
        }
        return output.map { Self(output: $0, scenes: scenes, themes: themes) }
    }
}

/// A scene: opens one module's playground window.
@MainActor
struct UiShellScene {
    let name: String
    /// The module whose views it draws.
    let module: String
    let open: @MainActor () -> Void
}

/// One shot scene in the receipt.
struct UiShellShot: Codable, Equatable {
    var scene: String
    var module: String
    var files: [String]
    /// Opening the window through the last PNG written.
    var ms: Double
    var error: String?
}

struct UiShellReceipt: Codable, Equatable {
    var shots: [UiShellShot]
    var totalMs: Double
    var themes: String
}

@MainActor
enum UiShellShoot {
    /// The repo's shipped theme files, found from this source file's place in the checkout.
    nonisolated static var repoThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Sources/UiLayerHost
            .deletingLastPathComponent().deletingLastPathComponent() // Prototypes/UiLayerHost
            .appending(path: "Resources/cmux-themes")
    }

    /// Every theme file's colors in `folder`, by file name.
    static func themeColors(in folder: URL) -> [String: ThemeFileColors] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var colors: [String: ThemeFileColors] = [:]
        for name in names {
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8),
                  let file = ThemeFileColors(name: name, themeFile: text) else { continue }
            colors[name] = file
        }
        return colors
    }

    /// The scenes, each holding its playground's owner so its window lives until the shot.
    static func scenes(themes: URL) -> [UiShellScene] {
        let colors = themeColors(in: themes)
        let tabs = TabBarPlaygroundWindow()
        let sidebar = SidebarStatesPlaygroundWindow(design: .shared)
        let allThemes = AllThemesPlaygroundWindow(folders: [themes])
        let keycaps = CmuxKeycapPlaygroundWindow()
        return [
            UiShellScene(name: "tabs", module: "CmuxNextTabs") { tabs.show() },
            UiShellScene(name: "sidebar-states", module: "CmuxNextSidebar") {
                sidebar.show(themes: SidebarStatesPlaygroundThemes(colors: colors))
            },
            UiShellScene(name: "all-themes", module: "CmuxNextDesign") { allThemes.show() },
            UiShellScene(name: "keycaps", module: "CmuxNextDesign") {
                keycaps.show(themes: CmuxToastPlaygroundThemes(colors: colors))
            },
        ]
    }

    /// Shoots `options.scenes` (every scene when empty) into `options.output` and writes receipt.json there.
    static func run(_ options: UiShellShootOptions) throws -> UiShellReceipt {
        let start = ContinuousClock.now
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let all = scenes(themes: options.themes)
        let unknown = options.scenes.filter { name in !all.contains { $0.name == name } }
        guard unknown.isEmpty else {
            throw UiShellShootError.unknownScenes(unknown, known: all.map(\.name))
        }
        let chosen = options.scenes.isEmpty ? all : all.filter { options.scenes.contains($0.name) }
        var shots: [UiShellShot] = []
        for scene in chosen {
            shots.append(shoot(scene, into: options.output))
        }
        let receipt = UiShellReceipt(shots: shots, totalMs: milliseconds(since: start), themes: options.themes.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: options.output.appending(path: "receipt.json"), options: .atomic)
        return receipt
    }

    private static func shoot(_ scene: UiShellScene, into output: URL) -> UiShellShot {
        let start = ContinuousClock.now
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        scene.open()
        // One turn for SwiftUI hosting views and deferred layout to settle before the draw.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        let opened = NSApp.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
        var shot = UiShellShot(scene: scene.name, module: scene.module, files: [], ms: 0)
        if opened.isEmpty { shot.error = "the scene opened no window" }
        for (index, window) in opened.enumerated() {
            let file = opened.count == 1 ? "\(scene.name).png" : "\(scene.name)-\(index + 1).png"
            do {
                try snapshot(window, to: output.appending(path: file))
                shot.files.append(file)
            } catch {
                shot.error = "\(file): \(error)"
            }
            window.orderOut(nil)
        }
        shot.ms = milliseconds(since: start)
        return shot
    }

    /// Draws `window`'s content view into a PNG at `path`, at the window's backing scale.
    static func snapshot(_ window: NSWindow, to path: URL) throws {
        guard let view = window.contentView else { throw UiShellShootError.noContentView }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rect = view.bounds
        guard rect.width > 0, rect.height > 0, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw UiShellShootError.noBitmap
        }
        view.cacheDisplay(in: rect, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UiShellShootError.noBitmap }
        try data.write(to: path, options: .atomic)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

enum UiShellShootError: Error, CustomStringConvertible {
    case unknownScenes([String], known: [String])
    case noContentView
    case noBitmap

    var description: String {
        switch self {
        case .unknownScenes(let names, let known):
            "unknown scene \(names.joined(separator: ", ")); scenes: \(known.joined(separator: ", "))"
        case .noContentView: "the window has no content view"
        case .noBitmap: "the view gave no bitmap"
        }
    }
}
