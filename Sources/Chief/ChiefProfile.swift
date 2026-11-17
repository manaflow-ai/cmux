import AppKit
import CmuxChief
import Foundation
import MessagesLabSidebar

/// Chief's look: the header and list avatar text (at most two characters;
/// an emoji counts as one) and an optional picture, kept in
/// `<Chief home>/state/profile.json` beside the conversations (cmux-next
/// keeps it in `profile.json` too). The picture wins over the text; with
/// neither, the conversation's initials show.
struct ChiefProfile: Codable, Equatable {
    var avatar: String?
    /// The avatar picture's file name in the state directory (a square PNG).
    var picture: String?
    /// Chief's display name (the settings panel's Name field); nil is "Chief".
    /// The owner's Chief participants carry it too (`renameChiefs(to:)`).
    var name: String?

    /// The name the header pill, the list rows and the sidebar's Home row show.
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? ChiefStrings.chiefName : trimmed
    }

    /// The saved profile's name ("Chief" before Chief has started).
    @MainActor
    static func currentName() -> String {
        guard let home = ChiefService.shared.home else { return ChiefStrings.chiefName }
        return load(from: home).displayName
    }

    /// Posted after the avatar is saved (the list and other headers re-read it).
    static let didChange = Notification.Name("ChiefProfile.didChange")

    /// The file a chosen picture is saved to.
    static let pictureFileName = "avatar.png"
    /// The saved picture's side in pixels: sharp at the 76 pt pinned tile on a 2x display.
    private static let pictureSide = 256

    static func url(in home: ChiefHome) -> URL {
        home.stateDirectory.appendingPathComponent("profile.json", isDirectory: false)
    }

    static func load(from home: ChiefHome) -> ChiefProfile {
        guard let data = try? Data(contentsOf: url(in: home)),
              let profile = try? JSONDecoder().decode(ChiefProfile.self, from: data) else { return ChiefProfile() }
        return profile
    }

    func save(to home: ChiefHome) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: home), options: .atomic)
    }

    /// The picture's file, when one is set and still on disk.
    func pictureURL(in home: ChiefHome) -> URL? {
        guard let picture, !picture.isEmpty, !picture.contains("/") else { return nil }
        let url = home.stateDirectory.appendingPathComponent(picture, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Saves `source` as the avatar picture: its centered square, scaled to
    /// ``pictureSide``, as PNG (the list draws the file into its disc as is).
    /// Returns the file name to keep in ``picture``.
    static func importPicture(from source: URL, into home: ChiefHome) throws -> String {
        guard let image = NSImage(contentsOf: source),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let square = cg.cropping(to: crop),
              let context = CGContext(data: nil, width: pictureSide, height: pictureSide, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: pictureSide, height: pictureSide))
        guard let scaled = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: home.stateDirectory.appendingPathComponent(pictureFileName, isDirectory: false), options: .atomic)
        return pictureFileName
    }

    /// `text` trimmed to the avatar's two characters; nil when empty.
    static func avatarText(_ text: String) -> String? {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `text` is letters and digits (a monogram) rather than an emoji.
    static func isMonogram(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

/// The one Chief avatar the header (40 pt), the conversation list (40 pt rows,
/// pinned tiles) and the sidebar's Home row (16 pt) all draw, so Chief has one
/// face everywhere:
///
/// - a profile picture, as is;
/// - avatar text: white initials on Messages' grey gradient
///   (MessagesLab `SidebarPalette.monogramTop/Bottom`), or an emoji on the grey disc (`groupDisc`);
/// - otherwise cmux-next's default Chief face, the bundled `ChiefAvatar` art
///   (`HomeHostView.defaultAvatar`).
enum ChiefAvatarArtwork {
    enum Kind: Equatable {
        case picture(URL)
        case monogram(String)
        case emoji(String)
        case chief
    }

    /// The bundled default face (the `ChiefAvatar` asset).
    static var defaultFace: NSImage? { NSImage(named: "ChiefAvatar") }

    /// What `profile` shows (picture, then text, then the default face).
    static func kind(_ profile: ChiefProfile, home: ChiefHome?) -> Kind {
        if let home, let picture = profile.pictureURL(in: home) { return .picture(picture) }
        guard let text = profile.avatar else { return .chief }
        return ChiefProfile.isMonogram(text) ? .monogram(String(text.prefix(2))) : .emoji(String(text.prefix(1)))
    }

    /// The saved profile's avatar kind (the default face before Chief has started).
    @MainActor
    static func current() -> Kind {
        guard let home = ChiefService.shared.home else { return .chief }
        return kind(ChiefProfile.load(from: home), home: home)
    }

    /// The avatar at `diameter` points. A picture or the default face is
    /// returned as is (callers clip it to the disc); text is drawn resolution
    /// independent.
    static func image(_ kind: Kind, diameter: CGFloat, isDark: Bool) -> NSImage {
        switch kind {
        case .picture(let url):
            if let image = NSImage(contentsOf: url) { return image }
        case .chief:
            if let face = defaultFace { return face }
        case .monogram, .emoji:
            break
        }
        return NSImage(size: NSSize(width: diameter, height: diameter), flipped: true) { rect in
            drawText(kind, in: rect, isDark: isDark)
            return true
        }
    }

    /// The list's avatar for `kind`. The list draws pictures from files, so
    /// the default face is written once to the state directory.
    @MainActor
    static func listAvatar(_ kind: Kind) -> CmuxSidebarEntry.Avatar? {
        switch kind {
        case .picture(let url): return .image(url.absoluteString)
        case .monogram(let text): return .monogram(text)
        case .emoji(let text): return .emoji(text)
        case .chief:
            guard let home = ChiefService.shared.home, let url = try? defaultFaceFile(in: home) else { return nil }
            return .image(url.absoluteString)
        }
    }

    private static func defaultFaceFile(in home: ChiefHome) throws -> URL {
        let url = home.stateDirectory.appendingPathComponent("avatar-chief-default.png", isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let face = defaultFace, let tiff = face.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        return url
    }

    /// Draws a text avatar into `rect` of a top-down context.
    private static func drawText(_ kind: Kind, in rect: CGRect, isDark: Bool) {
        let disc = NSBezierPath(ovalIn: rect)
        switch kind {
        case .monogram(let text):
            // Top-down: 90 degrees runs from the top (start) to the bottom (end).
            NSGradient(starting: isDark ? p3(132, 136, 145) : p3(166, 171, 184),
                       ending: isDark ? p3(104, 108, 117) : p3(134, 139, 151))?.draw(in: disc, angle: 90)
            let font = NSFont.boldSystemFont(ofSize: (rect.width * 0.42).rounded())
            let monogram = text.uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let width = monogram.size(withAttributes: attributes).width
            // Cap height centered, as the list draws it.
            let baseline = rect.midY + font.capHeight / 2
            monogram.draw(at: CGPoint(x: rect.midX - width / 2, y: baseline - font.ascender), withAttributes: attributes)
        case .emoji(let text):
            (isDark ? p3(72, 72, 74) : p3(209, 209, 214)).setFill()
            disc.fill()
            let font = NSFont.systemFont(ofSize: rect.width * 0.5)
            let emoji = text as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let size = emoji.size(withAttributes: attributes)
            emoji.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        case .picture, .chief:
            // No file: Messages' empty grey disc.
            (isDark ? p3(104, 108, 117) : p3(134, 139, 151)).setFill()
            disc.fill()
        }
    }

    private static func p3(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(displayP3Red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}
