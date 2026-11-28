import AppKit
import Foundation

// The shoot core every UI shell host shares: the leaf shell (cmux-ui-layer, UiShellShoot.swift) and the heavy-module
// hosts (cmux-ui-home), each with its own scenes. `HOST --shoot DIR [--scene a,b] [--themes DIR]` opens
// the chosen scenes' playground windows, draws each into a PNG with cacheDisplay (no Screen Recording permission),
// writes DIR/receipt.json with each scene's time, and exits. AppKit and Foundation only: no CmuxNext module, so a
// host links only the modules its own scenes draw.

/// `--shoot`, `--scene` and `--themes`.
public struct UiShellShootOptions: Equatable, Sendable {
    public var output: URL
    /// Scene names to shoot; empty shoots every scene.
    public var scenes: [String]
    /// The theme folder the playgrounds read (the repo's Resources/cmux-themes by default).
    public var themes: URL

    public init(output: URL, scenes: [String] = [], themes: URL) {
        self.output = output
        self.scenes = scenes
        self.themes = themes
    }

    /// The options when `--shoot DIR` is given, nil otherwise.
    public static func parse(arguments: [String], defaultThemes: URL = UiShellShooter.repoThemes) -> Self? {
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
public struct UiShellScene {
    public let name: String
    /// The module whose views it draws.
    public let module: String
    public let open: @MainActor () -> Void

    public init(name: String, module: String, open: @escaping @MainActor () -> Void) {
        self.name = name
        self.module = module
        self.open = open
    }
}

/// One shot scene in the receipt.
public struct UiShellShot: Codable, Equatable, Sendable {
    public var scene: String
    public var module: String
    public var files: [String]
    /// Opening the window through the last PNG written.
    public var ms: Double
    public var error: String?
}

public struct UiShellReceipt: Codable, Equatable, Sendable {
    public var shots: [UiShellShot]
    public var totalMs: Double
    public var themes: String
}

@MainActor
public enum UiShellShooter {
    /// The repo's shipped theme files, found from this source file's place in the checkout.
    public nonisolated static var repoThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Sources/<target>
            .deletingLastPathComponent().deletingLastPathComponent() // Prototypes/UiLayerHost
            .appending(path: "Resources/cmux-themes")
    }

    /// A host's `main` when `--shoot` is given: draws `scenes(themes)`, prints a line per scene, writes the receipt
    /// and exits (0 when every scene drew, 1 when one failed, 2 when none ran). Returns when `--shoot` is absent.
    public static func runIfAsked(arguments: [String] = CommandLine.arguments,
                                  scenes: @MainActor (URL) -> [UiShellScene]) {
        guard let options = UiShellShootOptions.parse(arguments: arguments) else { return }
        let app = NSApplication.shared
        // One shot: no Dock icon, no run loop of its own.
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        do {
            let receipt = try run(options, scenes: scenes(options.themes))
            let failed = receipt.shots.filter { $0.error != nil }
            for shot in receipt.shots {
                print("ui-shell: \(shot.scene) \(Int(shot.ms)) ms \(shot.files.joined(separator: " "))\(shot.error.map { " ERROR \($0)" } ?? "")")
            }
            print("ui-shell: \(receipt.shots.count) scenes in \(Int(receipt.totalMs)) ms -> \(options.output.path)")
            exit(failed.isEmpty ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("ui-shell: \(error)\n".utf8))
            exit(2)
        }
    }

    /// Shoots `options.scenes` of `all` (every scene when empty) into `options.output` and writes receipt.json there.
    public static func run(_ options: UiShellShootOptions, scenes all: [UiShellScene]) throws -> UiShellReceipt {
        let start = ContinuousClock.now
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
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
    public static func snapshot(_ window: NSWindow, to path: URL) throws {
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

public enum UiShellShootError: Error, CustomStringConvertible {
    case unknownScenes([String], known: [String])
    case noContentView
    case noBitmap

    public var description: String {
        switch self {
        case .unknownScenes(let names, let known):
            "unknown scene \(names.joined(separator: ", ")); scenes: \(known.joined(separator: ", "))"
        case .noContentView: "the window has no content view"
        case .noBitmap: "the view gave no bitmap"
        }
    }
}
