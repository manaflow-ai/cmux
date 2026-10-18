public import Foundation
public import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A collage (backgrounds plan phase 7): pictures arranged on one 16:10 canvas over a fill.
/// Layers are back to front; frames are fractions of the canvas from its top-left corner.
public nonisolated struct BackdropCollage: Codable, Equatable, Sendable {
    public nonisolated struct Layer: Codable, Equatable, Sendable {
        /// The picture: a ``BackdropSelection`` id (art, a macOS still or your own image).
        public var source: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var opacity: Double
        /// Corner rounding as a fraction of the layer's shorter side (0 square, 0.5 round).
        public var cornerRadius: Double

        public init(source: String, x: Double, y: Double, width: Double, height: Double, opacity: Double = 1, cornerRadius: Double = 0) {
            self.source = source
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.opacity = opacity
            self.cornerRadius = cornerRadius
        }
    }

    public var name: String
    /// The canvas color behind the layers, `#RRGGBB`.
    public var fill: String
    public var layers: [Layer]

    public init(name: String, fill: String = "#101010", layers: [Layer]) {
        self.name = name
        self.fill = fill
        self.layers = layers
    }
}

/// The person's collages: `Backgrounds/Collages/<id>.json` and the picture drawn from it,
/// `<id>.png`, which the window shows like any image. A saved edit gets a new id (and its old
/// files go), so no cache ever shows an earlier drawing under the same id.
public nonisolated struct BackdropCollages: Sendable {
    /// Why a collage cannot be saved; `code` is what the Settings page shows.
    public nonisolated struct SaveError: Error, Equatable, Sendable {
        public let code: String
        public static let invalid = Self(code: "cmux.settings.backdrop.collage.invalid")
        public static let noPictures = Self(code: "cmux.settings.backdrop.collage.no_pictures")
    }

    /// The picker collection collages are listed under.
    public static let collection = "collages"
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.collages", defaultValue: "Your collages", bundle: .module)
    }
    public static var untitled: String {
        String(localized: "backdrop.collage.untitled", defaultValue: "Collage", bundle: .module)
    }
    /// The size a collage is drawn at: sharp on a 5K display.
    public static let canvas = CGSize(width: 3200, height: 2000)
    public static let maximumLayers = 12

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The collages beside the backgrounds folder.
    public static var `default`: BackdropCollages? {
        BackdropArtDownloads.defaultFolder.map { BackdropCollages(folder: $0.appendingPathComponent("Collages", isDirectory: true)) }
    }

    /// An id this store makes: letters, digits and dashes only, so it never names another path.
    public static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public func imageURL(_ id: String) -> URL? {
        Self.isValidID(id) ? folder.appendingPathComponent("\(id).png") : nil
    }

    private func recordURL(_ id: String) -> URL? {
        Self.isValidID(id) ? folder.appendingPathComponent("\(id).json") : nil
    }

    public func collage(_ id: String) -> BackdropCollage? {
        guard let url = recordURL(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BackdropCollage.self, from: data)
    }

    /// Every collage drawn, newest first.
    public func list(fileManager: FileManager = .default) -> [BackdropSelection] {
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "png" && Self.isValidID($0.deletingPathExtension().lastPathComponent) }
            .map { url in (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent < $1.0.lastPathComponent }
            .map { BackdropSelection.collage(id: $0.0.deletingPathExtension().lastPathComponent) }
    }

    /// Draws and saves `collage` under a new id, removing `replacing`'s files once it is saved.
    /// A layer must name a still picture (not a video, the desktop or another collage) and lie on
    /// the canvas; at most ``maximumLayers``, at least one that draws.
    public func save(_ collage: BackdropCollage, replacing: String? = nil) throws -> String {
        guard collage.layers.count <= Self.maximumLayers, collage.name.count <= 100, Self.color(collage.fill) != nil,
              collage.layers.allSatisfy(Self.isValid) else { throw SaveError.invalid }
        guard let image = Self.render(collage) else { throw SaveError.noPictures }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "c-" + UUID().uuidString.lowercased().prefix(13).replacingOccurrences(of: "-", with: "")
        guard let png = imageURL(id), let record = recordURL(id),
              let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SaveError.invalid
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(collage).write(to: record, options: .atomic)
        if let replacing, replacing != id { try? delete(replacing) }
        return id
    }

    public func delete(_ id: String) throws {
        guard let png = imageURL(id), let record = recordURL(id) else { throw SaveError.invalid }
        try? FileManager.default.removeItem(at: record)
        try FileManager.default.removeItem(at: png)
    }

    static func isValid(_ layer: BackdropCollage.Layer) -> Bool {
        let numbers = [layer.x, layer.y, layer.width, layer.height, layer.opacity, layer.cornerRadius]
        guard numbers.allSatisfy(\.isFinite), layer.width > 0.01, layer.height > 0.01,
              layer.x > -1, layer.y > -1, layer.x < 1, layer.y < 1, layer.width <= 2, layer.height <= 2,
              (0...1).contains(layer.opacity), (0...0.5).contains(layer.cornerRadius),
              let source = BackdropSelection(id: layer.source) else { return false }
        switch source {
        case .art, .file, .system: return !source.isVideo
        case .desktop, .collage: return false
        }
    }

    static func color(_ hex: String) -> CGColor? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        let channel = { (shift: UInt32) in CGFloat((value >> shift) & 0xFF) / 255 }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }

    /// The collage drawn on ``canvas``: the fill, then each layer's picture filling its frame
    /// (cropped to the frame's shape around its center), rounded and faded as set. Nil when no
    /// layer's picture could be read.
    static func render(_ collage: BackdropCollage) -> CGImage? {
        let size = canvas
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(color(collage.fill) ?? CGColor(gray: 0.06, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        var drew = false
        for layer in collage.layers {
            // Drawn bottom-left first: the layer's top-left frame flipped.
            let frame = CGRect(x: layer.x * size.width, y: size.height - (layer.y + layer.height) * size.height,
                               width: layer.width * size.width, height: layer.height * size.height)
            guard let url = BackdropSelection(id: layer.source)?.imageURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: Int(max(frame.width, frame.height) * 1.5),
                  ] as CFDictionary) else { continue }
            let scale = max(frame.width / CGFloat(picture.width), frame.height / CGFloat(picture.height))
            let drawn = CGRect(x: frame.midX - CGFloat(picture.width) * scale / 2, y: frame.midY - CGFloat(picture.height) * scale / 2,
                               width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.saveGState()
            let radius = min(frame.width, frame.height) * layer.cornerRadius
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.setAlpha(layer.opacity)
            context.draw(picture, in: drawn)
            context.restoreGState()
            drew = true
        }
        return drew ? context.makeImage() : nil
    }
}
