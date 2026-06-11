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

@Test func locatorReturnsNilWhenNoAppIconSet() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(AppIconImageLocator(fileManager: .default).bestIconURL(inProjectRoot: root) == nil)
}
