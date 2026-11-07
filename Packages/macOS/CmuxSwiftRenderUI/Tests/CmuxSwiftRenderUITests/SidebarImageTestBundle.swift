import AppKit
import Foundation
import Testing

/// Compiles a namespaced catalog so the fixture uses the app's real bundle lookup.
@MainActor
struct SidebarImageTestBundle {
    let url: URL
    let bundle: Bundle

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "com.cmux.sidebar-image-tests.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let catalog = url.appendingPathComponent("Fixture.xcassets")
        let agents = catalog.appendingPathComponent("AgentIcons")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["info": ["version": 1]])
            .write(to: catalog.appendingPathComponent("Contents.json"))
        try JSONSerialization.data(withJSONObject: [
            "info": ["version": 1], "properties": ["provides-namespace": true],
        ]).write(to: agents.appendingPathComponent("Contents.json"))
        for (name, points) in [("AgentIcons/Codex", 14), ("AgentIcons/HermesAgent", 1024), ("AppIcon", 14)] {
            let imageSet = catalog.appendingPathComponent(name).appendingPathExtension("imageset")
            try FileManager.default.createDirectory(at: imageSet, withIntermediateDirectories: true)
            let image = NSImage(size: NSSize(width: CGFloat(points), height: CGFloat(points)), flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                return true
            }
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: imageSet.appendingPathComponent("mark.png"))
            try JSONSerialization.data(withJSONObject: [
                "images": [["idiom": "universal", "filename": "mark.png", "scale": "1x"]],
                "info": ["version": 1],
            ]).write(to: imageSet.appendingPathComponent("Contents.json"))
        }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "actool", "--compile", resources.path, "--platform", "macosx",
            "--minimum-deployment-target", "14.0", catalog.path,
        ]
        let output = Pipe()
        compiler.standardOutput = output
        compiler.standardError = output
        try compiler.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw NSError(domain: "SidebarImageTestBundle", code: Int(compiler.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self),
            ])
        }
        bundle = try #require(Bundle(url: url))
    }
}
