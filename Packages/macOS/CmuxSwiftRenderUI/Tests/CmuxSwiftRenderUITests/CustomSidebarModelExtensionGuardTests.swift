import CmuxSwiftRender
import Foundation
import Testing

@testable import CmuxSwiftRenderUI

/// The interpreter model only renders interpreted sources.
///
/// `reload()` used to branch on "is it `.swift`?" and treat everything else as declarative JSON, so
/// any file at all that reached the model was decoded as a sidebar document — including a `.url` or
/// `.html` the web path had refused. That made the extension check at the mount site the only thing
/// standing between an unqualified file and the privileged interpreted lane, and a single missed
/// branch there was enough to lose it. The model now refuses, so the guarantee does not depend on
/// every caller remembering.
@Suite("CustomSidebarModel extension guard")
@MainActor
struct CustomSidebarModelExtensionGuardTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-model-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ contents: String, to directory: URL, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let sidebarDocument = """
    {"version":1,"root":{"type":"text","text":"pwn"}}
    """

    @Test("a .json file still decodes as a sidebar document")
    func jsonStillLoads() throws {
        let dir = try directory()
        let url = try write(sidebarDocument, to: dir, as: "board.json")

        let model = CustomSidebarModel(fileURL: url)
        model.reload()

        guard case .json = model.state else {
            Issue.record("expected .json, got \(model.state)")
            return
        }
    }

    @Test("a .swift file still loads as interpreted source")
    func swiftStillLoads() throws {
        let dir = try directory()
        let url = try write("Text(\"hi\")", to: dir, as: "board.swift")

        let model = CustomSidebarModel(fileURL: url)
        model.reload()

        guard case .swiftSource = model.state else {
            Issue.record("expected .swiftSource, got \(model.state)")
            return
        }
    }

    @Test(
        "a non-interpreted extension is refused rather than decoded",
        arguments: ["board.url", "board.html", "board.txt", "board.JSON", "board.SWIFT"]
    )
    func nonInterpretedExtensionIsRefused(fileName: String) throws {
        let dir = try directory()
        let url = try write(sidebarDocument, to: dir, as: fileName)

        let model = CustomSidebarModel(fileURL: url)
        model.reload()

        if case .json = model.state {
            Issue.record("\(fileName) was decoded as a sidebar document")
        }
        if case .swiftSource = model.state {
            Issue.record("\(fileName) was loaded as interpreted source")
        }
    }

    // Precedence still flips between the two interpreted extensions, which is the behaviour the
    // guard must not cost: `.swift` wins while it exists, `.json` takes over when it is deleted.
    @Test("interpreted precedence still flips across reloads")
    func interpretedPrecedenceStillFlips() throws {
        let dir = try directory()
        try write(sidebarDocument, to: dir, as: "board.json")
        let swiftURL = try write("Text(\"hi\")", to: dir, as: "board.swift")

        let model = CustomSidebarModel(fileURL: swiftURL)
        model.reload()
        #expect(model.fileURL.lastPathComponent == "board.swift")

        try FileManager.default.removeItem(at: swiftURL)
        model.reload()

        #expect(model.fileURL.lastPathComponent == "board.json")
        guard case .json = model.state else {
            Issue.record("expected .json after the flip, got \(model.state)")
            return
        }
    }

    // A model pointed at a web file must not be rescued by resolution either: `preferredFileURL`
    // looks for interpreted siblings, and finding none it keeps the web file, which must then be
    // refused rather than read.
    @Test("a web file with no interpreted sibling stays refused")
    func webFileWithoutSiblingStaysRefused() throws {
        let dir = try directory()
        let url = try write(sidebarDocument, to: dir, as: "board.url")

        let model = CustomSidebarModel(fileURL: url)
        model.reload()

        if case .json = model.state {
            Issue.record("a .url file was decoded as a sidebar document")
        }
    }
}
