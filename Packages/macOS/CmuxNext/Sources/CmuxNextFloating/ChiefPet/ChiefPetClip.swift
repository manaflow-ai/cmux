public import CmuxNextDesign
import CoreGraphics
import Foundation
import ImageIO

/// An upload's frames as the pet plays them: a GIF's frames with their own delays, or one still.
nonisolated struct ChiefPetClip: Sendable {
    /// The most frames kept (at most 256 x 256 px each, about 16 MB in all).
    static let maximumFrames = 64
    let frames: [CGImage]
    /// Seconds each frame shows.
    let delays: [TimeInterval]

    /// The frames of `file` (read off the main actor); nil when it cannot be read.
    init?(file: URL) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), Self.maximumFrames)
        // A moving GIF's frames are at most 256 px; a still is the 512 px PNG the upload made.
        let largest = count > 1 ? ChiefAvatarUploads.maximumGIFPixels : ChiefAvatarUploads.stillSide
        var frames: [CGImage] = [], delays: [TimeInterval] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            // A frame past the GIF limit is never decoded (the upload checked them; this file could have changed).
            guard let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int,
                  max(width, height) <= largest,
                  let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            frames.append(frame)
            // A delay under 20 ms plays at 100 ms, as browsers play it.
            delays.append(delay < 0.02 ? 0.1 : delay)
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.delays = delays
    }
}

/// How the Chief Settings popover's grid offers an upload before there is one. The gallery captures
/// each (`debug.tunables` set `chiefPet.uploadAffordance`); the "+" tile ships.
public nonisolated enum ChiefPetUploadAffordance: String, Sendable, CaseIterable, TunableChoice {
    case tile, button, drop

    public var tunableTitle: String {
        switch self {
        case .tile: "A + tile after the nine"
        case .button: "A button under the grid"
        case .drop: "Drop only, with a hint"
        }
    }
}

/// The Chief pet's tunables (Debug Settings, DEV and NIGHTLY).
public nonisolated struct ChiefPetTunables {
    public nonisolated init() {}

    static let section = TunableSection(id: "chiefPet", title: "Chief Pet", symbol: "pawprint", order: 44)

    public static let uploadAffordance = Tunable<ChiefPetUploadAffordance>.choice(
        "chiefPet.uploadAffordance", section, "Upload affordance",
        help: "How the Chief Settings popover offers Upload Your Own… before there is an upload: a + tile after the nine characters, a button under the grid, or a drop with a hint. Dropping a picture on the grid works in all three.",
        default: .tile, code: "ChiefPetTunables.uploadAffordance")

    public static var all: [TunableDescriptor] { [uploadAffordance.descriptor] }
}
