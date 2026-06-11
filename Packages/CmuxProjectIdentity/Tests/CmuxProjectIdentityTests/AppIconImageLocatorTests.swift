import Foundation
import Testing
@testable import CmuxProjectIdentity

private func makeAppIconFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppIconFixture-\(UUID().uuidString)", isDirectory: true)
    let set = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    // two PNGs; the 1024 one must win
    try Data([0x89]).write(to: set.appendingPathComponent("small.png"))   // 40x40
    try Data([0x89]).write(to: set.appendingPathComponent("marketing.png")) // 1024x1024
    let contents = """
    {"images":[
      {"size":"20x20","scale":"2x","filename":"small.png"},
      {"size":"1024x1024","scale":"1x","filename":"marketing.png"}
    ],"info":{"version":1,"author":"xcode"}}
    """
    try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    return root
}

@Test func locatorPicksLargestImage() throws {
    let root = try makeAppIconFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = AppIconImageLocator(fileManager: .default).bestIconURL(inProjectRoot: root)
    #expect(url?.lastPathComponent == "marketing.png")
}

/// Regression: a shallower (or equal-depth) `AppIcon.appiconset` that has no
/// usable image must NOT shadow a deeper one that does. Mirrors a real project
/// (FilmLab) that has an empty `FilmLabMac/.../AppIcon.appiconset` alongside a
/// populated `FilmLab/.../AppIcon.appiconset`.
@Test func locatorSkipsUnusableAppIconSetShadowingUsableOne() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppIconShadow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Shallow, EMPTY AppIcon.appiconset (no Contents.json, no images).
    let empty = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

    // Deeper, USABLE AppIcon.appiconset.
    let good = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    try Data([0x89]).write(to: good.appendingPathComponent("marketing.png"))
    let contents = """
    {"images":[{"size":"1024x1024","scale":"1x","filename":"marketing.png"}],"info":{"version":1,"author":"xcode"}}
    """
    try contents.write(to: good.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

    let url = AppIconImageLocator(fileManager: .default).bestIconURL(inProjectRoot: root)
    #expect(url?.lastPathComponent == "marketing.png")
}

@Test func locatorReturnsNilWhenNoAppIconSet() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(AppIconImageLocator(fileManager: .default).bestIconURL(inProjectRoot: root) == nil)
}
