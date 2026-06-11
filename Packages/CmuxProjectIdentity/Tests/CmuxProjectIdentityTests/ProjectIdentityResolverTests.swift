import AppKit
import Foundation
import Testing
@testable import CmuxProjectIdentity

private func writePNG(_ color: NSColor, to url: URL, side: Int = 32) throws {
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
        color.setFill(); r.fill(); return true
    }
    var rect = NSRect(x: 0, y: 0, width: side, height: side)
    let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    let rep = NSBitmapImageRep(cgImage: cg)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

@Test func resolverReturnsNameMonogramIconAndColor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RootFix-\(UUID().uuidString)/cmux", isDirectory: true)
    let set = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try writePNG(.red, to: set.appendingPathComponent("icon.png"))
    try """
    {"images":[{"size":"1024x1024","scale":"1x","filename":"icon.png"}],"info":{"version":1}}
    """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolver = ProjectIdentityResolver(fileManager: .default)
    let identity = await resolver.resolve(projectRootPath: root.path)

    #expect(identity.projectName == "cmux")
    #expect(identity.monogram == "CM")
    #expect(identity.iconImageData != nil)
    #expect(identity.dominantColorHex == "#FF0000")
}

@Test func resolverFallsBackWhenNoIcon() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("webapp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = await ProjectIdentityResolver(fileManager: .default).resolve(projectRootPath: root.path)
    #expect(identity.iconImageData == nil)
    #expect(identity.dominantColorHex == nil)
    #expect(identity.monogram.count >= 1)
}
