import AppKit
@testable import CmuxNextActions
@testable import CmuxNextChiefPetWiring
import CmuxNextDesign
@testable import CmuxNextFloating
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// The gallery of Upload Your Own… (Leo 2026-10-26: "upload their own"): the real Chief Settings card
/// drawn offscreen in light and dark for each affordance (`chiefPet.uploadAffordance`), before uploads
/// existed, and with a synthetic upload worn. The popover is its own window, which the app's per-window
/// capture leaves out, so the PR's pictures come from here: one sheet written to the package's
/// `.build/chief-upload-gallery.png` (ignored by git), which a fleet step returns with
/// `cmux-ci run --artifact Packages/macOS/CmuxNext/.build/chief-upload-gallery.png`.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChiefAvatarUploadGalleryTests {
    enum Variant: String, CaseIterable {
        case before, tile, button, drop, worn
    }

    /// A synthetic avatar: a round face on a transparent square, drawn here.
    static func face(in folder: URL) throws -> URL {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 8)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 40, y: 70, width: 14, height: 14)).fill()
            NSBezierPath(ovalIn: NSRect(x: 74, y: 70, width: 14, height: 14)).fill()
            NSBezierPath(roundedRect: NSRect(x: 44, y: 36, width: 40, height: 10), xRadius: 5, yRadius: 5).fill()
            return true
        }
        let file = folder.appending(path: "synthetic-face.png")
        let tiff = try #require(image.tiffRepresentation)
        try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: file)
        return file
    }

    func card(_ variant: Variant, appearance: NSAppearance.Name, folder: URL) async throws -> NSImage {
        let url = folder.appending(path: "cmux-\(variant)-\(appearance.rawValue).json")
        // The cards labels take the apps look when they are made: the card is made in `appearance`.
        let appLook = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = appLook }
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let affordance: ChiefPetUploadAffordance = switch variant {
        case .button: .button
        case .drop: .drop
        default: .tile
        }
        TunableStore.shared.register(ChiefPetTunables.all)
        TunableStore.shared.activate(file: nil)  // overrides apply (as in DEV and NIGHTLY)
        _ = TunableStore.shared.set(ChiefPetTunables.uploadAffordance.key, .choice(affordance.rawValue))
        let uploads = variant == .before ? nil : ChiefAvatarUploads(folder: folder.appending(path: "uploads-\(variant)-\(appearance.rawValue)"))
        if variant == .worn, let uploads {
            try await uploads.store(from: Self.face(in: folder), for: ChiefAvatarUploads.key(chief: HomeChiefAvatars.defaultChief),
                                over: HomeChiefPetSetting.defaultMascot)
        }
        let home = folder.appending(path: "brain")
        let popover = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        let rows = ChiefPetSettingsRows(settings: { settings }, homes: ChiefPetHomes(),
                                        picks: ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief), uploads: uploads)
        rows.install(in: popover, addRow: { popover.addAppearanceRow($0, control: $1) }, open: { false })
        if variant == .worn, let uploads { popover.setAvatar(picture: NSImage(contentsOf: try #require(uploads.uploads.values.first).still), text: nil) }
        try? await Task.sleep(for: .milliseconds(50))  // the rows' first settings read
        let size = popover.fittingSize
        let backing = NSView(frame: NSRect(origin: .zero, size: size))
        backing.wantsLayer = true
        let window = NSWindow(contentRect: backing.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = backing
        defer { window.close() }
        backing.addSubview(popover)
        popover.frame = backing.bounds
        backing.appearance = NSAppearance(named: appearance)
        backing.effectiveAppearance.performAsCurrentDrawingAppearance {
            backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        backing.layoutSubtreeIfNeeded()
        backing.displayIfNeeded()
        let rep = try #require(backing.bitmapImageRepForCachingDisplay(in: backing.bounds))
        backing.cacheDisplay(in: backing.bounds, to: rep)
        let image = NSImage(size: backing.bounds.size)
        image.addRepresentation(rep)
        _ = TunableStore.shared.set(ChiefPetTunables.uploadAffordance.key, nil)
        return image
    }

    @Test func drawsEveryAffordanceLightAndDark() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-avatar-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cells: [(NSImage, Int, Int)] = []
        for (row, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            for (column, variant) in Variant.allCases.enumerated() {
                cells.append((try await card(variant, appearance: appearance, folder: folder), column, row))
            }
        }
        let width = cells.map(\.0.size.width).max() ?? 0, height = cells.map(\.0.size.height).max() ?? 0
        #expect(width > 100 && height > 100)
        let gap: CGFloat = 16
        let sheet = NSImage(size: NSSize(width: CGFloat(Variant.allCases.count) * (width + gap) + gap, height: 2 * (height + gap) + gap))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (image, column, row) in cells {
            // Light on top: AppKit's y grows upward.
            image.draw(at: NSPoint(x: gap + CGFloat(column) * (width + gap), y: gap + CGFloat(1 - row) * (height + gap) + height - image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent(".build/chief-upload-gallery.png"))
    }
}
