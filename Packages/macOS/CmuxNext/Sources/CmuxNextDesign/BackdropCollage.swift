public import Foundation

/// Pictures arranged back to front on a 16:10 backdrop, with frames measured from the top left.
public nonisolated struct BackdropCollage: Codable, Equatable, Sendable {
    /// One still picture, cropped to its normalized frame.
    public nonisolated struct Layer: Codable, Equatable, Sendable {
        /// A bundled-art, system-wallpaper or user-image selection id, authorized separately by the caller.
        public var source: String
        /// The frame's leading edge, as a fraction of canvas width.
        public var x: Double
        /// The frame's top edge, as a fraction of canvas height.
        public var y: Double
        /// The frame's fraction of canvas width.
        public var width: Double
        /// The frame's fraction of canvas height.
        public var height: Double
        /// Picture opacity, from zero to one.
        public var opacity: Double
        /// Rounding as a fraction of the frame's shorter side, from zero to one half.
        public var cornerRadius: Double

        /// Creates a layer with an opaque, square frame unless specified otherwise.
        public init(source: String, x: Double, y: Double, width: Double, height: Double,
                    opacity: Double = 1, cornerRadius: Double = 0) {
            self.source = source
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.opacity = opacity
            self.cornerRadius = cornerRadius
        }
    }

    /// A typed failure for callers to present through their own localized surface.
    public nonisolated enum Failure: Error, Equatable, Sendable {
        /// The record, geometry, selection kind or storage id is invalid.
        case invalid
        /// The caller did not authorize this source id for the operation.
        case sourceNotAllowed(String)
        /// An authorized source could not be decoded as a still picture.
        case unreadableSource(String)
        /// Core Graphics or Image I/O could not produce the drawing.
        case renderingFailed
    }

    /// The person's title, at most 100 characters; an empty title is allowed.
    public var name: String
    /// The opaque canvas fill, in `#RRGGBB` form.
    public var fill: String
    /// At most twelve layers, ordered back to front.
    public var layers: [Layer]

    /// Creates a record; call ``validate()`` before consuming decoded or edited data.
    public init(name: String, fill: String = "#101010", layers: [Layer]) {
        self.name = name
        self.fill = fill
        self.layers = layers
    }

    /// Refuses invalid records, off-canvas frames, non-still sources and completely invisible compositions.
    ///
    /// This checks shape, not file authority. ``BackdropCollageRenderer`` also requires an explicit source map.
    public func validate() throws {
        guard name.count <= 100, fill.count == 7, fill.hasPrefix("#"), UInt32(fill.dropFirst(), radix: 16) != nil,
              (1...12).contains(layers.count), layers.contains(where: { $0.opacity > 0 }) else { throw Failure.invalid }
        for layer in layers {
            guard [layer.x, layer.y, layer.width, layer.height, layer.opacity, layer.cornerRadius].allSatisfy(\.isFinite),
                  layer.x >= 0, layer.y >= 0, layer.width > 0, layer.height > 0,
                  layer.x + layer.width <= 1, layer.y + layer.height <= 1,
                  (0...1).contains(layer.opacity), (0...0.5).contains(layer.cornerRadius),
                  let selection = BackdropSelection(id: layer.source), !selection.isVideo else { throw Failure.invalid }
            switch selection {
            case .art, .system, .file: break
            case .desktop: throw Failure.invalid
            }
        }
    }
}
