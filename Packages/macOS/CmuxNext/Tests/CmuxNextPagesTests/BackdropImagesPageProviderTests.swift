import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The Settings page's own-background ops (`cmux.settings.backdrop.image.*`): a link refused by
/// its scheme comes back as the code the page words, only the folder's own images can be removed
/// or revealed, and Show in Finder with no image reveals the folder.
@MainActor @Suite struct BackdropImagesPageProviderTests {
    static let context = PageCallContext(page: "cmux.settings")

    @Test func theOpsServeOnlyTheFoldersOwnImages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let images = BackdropUserImages(folder: folder)
        try Data(repeating: 1, count: 1000).write(to: images.folder.appendingPathComponent("Sea.png"))
        var revealed: [[URL]] = []
        var used: [URL] = []
        var current: BackdropSelection?
        let provider = BackdropImagesPageProvider(images: images, files: BackgroundWork(label: "test.backdrop-images"), use: { used.append($0); return "file:\($0.path)" },
                                                  inUse: { current }, reveal: { revealed.append($0) })
        let call = { (op: String, params: JSONValue) in
            try await provider.call(BackdropImagesPageProvider.prefix + op, params: params, context: Self.context)
        }

        #expect(try await call("usage", [:])["bytes"]?.doubleValue == 1000)
        do {
            _ = try await call("link", ["url": "http://example.com/a.png"])
            Issue.record("an http link was downloaded")
        } catch let error as PageError {
            #expect(error.code == BackdropUserImages.ImportError.notHTTPS.code)
        }
        #expect(used.isEmpty)

        let own = "file:\(images.folder.appendingPathComponent("Sea.png").path)"
        _ = try await call("reveal", ["id": .string(own)])
        _ = try await call("reveal", [:])
        #expect(revealed == [[images.folder.appendingPathComponent("Sea.png")], [images.folder]])
        await #expect(throws: PageError.self) { try await call("remove", ["id": "file:/etc/hosts"]) }
        await #expect(throws: PageError.self) { try await call("remove", ["id": "starryNight"]) }
        // The background in use is refused natively, whatever the page shows.
        current = BackdropSelection(id: own)
        do {
            _ = try await call("remove", ["id": .string(own)])
            Issue.record("the background in use was removed")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.backdrop.in_use")
        }
        current = nil
        #expect(try await call("remove", ["id": .string(own)])["bytes"]?.doubleValue == 0)
        await #expect(throws: PageError.self) { try await call("nothing", [:]) }
    }
}
