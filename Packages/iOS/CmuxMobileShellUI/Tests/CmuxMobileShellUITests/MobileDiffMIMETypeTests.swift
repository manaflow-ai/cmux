import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileDiffMIMETypeTests {
    @Test(arguments: [
        ("index.html", "text/html"),
        ("main.mjs", "text/javascript"),
        ("worker.js", "text/javascript"),
        ("styles.css", "text/css"),
        ("config.json", "application/json"),
        ("highlighter.wasm", "application/wasm"),
        ("unknown.bin", "application/octet-stream"),
    ])
    func mapsAssetExtension(path: String, expected: String) {
        #expect(MobileDiffMIMEType().value(forPath: path) == expected)
    }
}
