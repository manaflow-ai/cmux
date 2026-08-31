import AppKit
import SwiftUI

/// Renders scenes to PNG files offscreen.
///
/// `ImageRenderer` rasterises a SwiftUI view without a window, so this needs no
/// Screen Recording permission and produces byte-identical output run to run.
@MainActor
struct GalleryRenderer {
    let outputDirectory: URL
    let scale: CGFloat

    func render(_ scenes: [GalleryScene]) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        for scene in scenes {
            for scheme in [ColorScheme.dark, .light] {
                let suffix = scheme == .dark ? "dark" : "light"
                let url = outputDirectory.appendingPathComponent("\(scene.name)-\(suffix).png")
                try write(scene: scene, scheme: scheme, to: url)
                print("rendered \(url.lastPathComponent)")
            }
        }
    }

    private func write(scene: GalleryScene, scheme: ColorScheme, to url: URL) throws {
        let background = scheme == .dark
            ? Color(nsColor: NSColor(srgbRed: 0.106, green: 0.110, blue: 0.118, alpha: 1))
            : Color(nsColor: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.953, alpha: 1))

        let wrapped = scene.content
            .frame(width: scene.width, alignment: .leading)
            .padding(.vertical, 12)
            .background(background)
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw GalleryError.renderFailed(scene.name)
        }
        try png.write(to: url)
    }
}

enum GalleryError: Error, CustomStringConvertible {
    case renderFailed(String)

    var description: String {
        switch self {
        case .renderFailed(let name):
            return "failed to rasterise scene '\(name)'"
        }
    }
}
