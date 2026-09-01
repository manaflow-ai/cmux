import Foundation
import Testing

@testable import CmuxFoundation

@Suite
struct CmuxValidatedImageAssetTests {
    @Test
    func resolvesRelativeImageAndRejectsUnsafeSVG() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-validated-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("cmux.json")
        let imageURL = directory.appendingPathComponent("icon.png")
        let pngData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try pngData.write(to: imageURL)

        let prepared = CmuxValidatedImageAsset.prepare(
            "icon.png",
            relativeToConfig: configURL.path,
            globalConfigPath: configURL.path
        )
        guard case .success(let asset) = prepared else {
            Issue.record("A valid relative PNG should pass validation: \(prepared)")
            return
        }
        #expect(asset.resolvedPath == imageURL.standardizedFileURL.path)
        #expect(asset.data == pngData)

        let validSVGURL = directory.appendingPathComponent("valid.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Hello</text></svg>"
            .write(to: validSVGURL, atomically: true, encoding: .utf8)
        let validSVG = CmuxValidatedImageAsset.prepare(
            validSVGURL.path,
            relativeToConfig: configURL.path,
            globalConfigPath: configURL.path
        )
        guard case .success = validSVG else {
            Issue.record("A plain SVG with text content should pass validation: \(validSVG)")
            return
        }

        let unsafeSVGURL = directory.appendingPathComponent("unsafe.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
            .write(to: unsafeSVGURL, atomically: true, encoding: .utf8)
        let unsafe = CmuxValidatedImageAsset.prepare(
            unsafeSVGURL.path,
            relativeToConfig: configURL.path,
            globalConfigPath: configURL.path
        )
        #expect(unsafe == .failure(.unsafeSVG))
    }

    @Test
    func rejectsOversizedFilesBeforeReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-validated-image-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("large.png")
        try Data(repeating: 0, count: CmuxValidatedImageAsset.maxImageBytes + 1).write(to: imageURL)
        var requestedContentPaths: [String] = []
        let result = CmuxValidatedImageAsset.prepare(
            imageURL.path,
            relativeToConfig: nil,
            globalConfigPath: directory.appendingPathComponent("cmux.json").path,
            readContents: { path in
                requestedContentPaths.append(path)
                return nil
            }
        )
        #expect(result == .failure(.tooLarge))
        #expect(requestedContentPaths.isEmpty)
    }

    @Test
    func rejectsLargerReplacementAfterMetadataCheckWithBoundedRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-validated-image-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("icon.png")
        try Data(repeating: 0x01, count: 1).write(to: imageURL)
        var replacementPerformed = false
        var bytesRead: Int?

        let result = CmuxValidatedImageAsset.prepare(
            imageURL.path,
            relativeToConfig: nil,
            globalConfigPath: directory.appendingPathComponent("cmux.json").path,
            readContents: { path in
                // Replace the file after metadata validation, modeling the
                // TOCTOU window that must not trigger an unbounded read.
                replacementPerformed = true
                try? Data(
                    repeating: 0x02,
                    count: CmuxValidatedImageAsset.maxImageBytes + 1
                ).write(to: URL(fileURLWithPath: path), options: .atomic)
                let data = CmuxValidatedImageAsset.boundedImageContents(atPath: path)
                bytesRead = data?.count
                return data
            }
        )

        #expect(replacementPerformed)
        #expect(bytesRead == CmuxValidatedImageAsset.maxImageBytes + 1)
        #expect(result == .failure(.tooLarge))
    }

    @Test
    func rejectsNamespacedAndEscapedSVGContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-validated-image-svg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsafeSVGs = [
            (
                "prefixed-script.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:svg=\"http://www.w3.org/2000/svg\"><svg:script>alert(1)</svg:script></svg>"
            ),
            (
                "prefixed-style.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:svg=\"http://www.w3.org/2000/svg\"><svg:style>@\\69mport '//example.com/theme.css';</svg:style></svg>"
            ),
            (
                "escaped-import.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>@\\69mport '//example.com/theme.css';</style></svg>"
            ),
            (
                "escaped-url.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect style=\"fill:u\\72l(//example.com/icon.svg#mark)\"/></svg>"
            ),
        ]

        for (fileName, source) in unsafeSVGs {
            let imageURL = directory.appendingPathComponent(fileName)
            try source.write(to: imageURL, atomically: true, encoding: .utf8)
            let result = CmuxValidatedImageAsset.prepare(
                imageURL.path,
                relativeToConfig: nil,
                globalConfigPath: directory.appendingPathComponent("cmux.json").path
            )
            #expect(
                result == .failure(.unsafeSVG),
                "Expected \(fileName) to be rejected, got \(result)"
            )
        }
    }
}
