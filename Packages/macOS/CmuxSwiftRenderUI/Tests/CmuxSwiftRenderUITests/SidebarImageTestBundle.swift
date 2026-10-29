import AppKit
import Foundation
import Testing

/// An on-disk image bundle exercising the same lookup used by sidebar renderers.
@MainActor
struct SidebarImageTestBundle {
    let url: URL
    let bundle: Bundle

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("AgentIcons"),
            withIntermediateDirectories: true
        )
        let info: [String: String] = [
            "CFBundleIdentifier": "com.cmux.sidebar-image-tests.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        for (name, points) in [("AgentIcons/Codex", 14), ("AgentIcons/HermesAgent", 1024), ("AppIcon", 14)] {
            let image = NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                return true
            }
            let data = try #require(image.tiffRepresentation)
            try data.write(to: resources.appendingPathComponent(name).appendingPathExtension("tiff"))
        }
        bundle = try #require(Bundle(url: url))
    }
}
