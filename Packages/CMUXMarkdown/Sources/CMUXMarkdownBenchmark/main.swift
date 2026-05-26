import CMUXMarkdown
import CoreGraphics
import CoreText
import Foundation

let iterations = argumentValue("--iterations").flatMap(Int.init) ?? 200
let blocks = argumentValue("--blocks").flatMap(Int.init) ?? 800
let markdown = fixture(blocks: blocks)
let parser = CMUXMarkdownParser()
let renderer = CMUXMarkdownCoreTextRenderer()

let parseStart = DispatchTime.now().uptimeNanoseconds
var document = CMUXMarkdownDocument(blocks: [])
for _ in 0..<iterations {
    document = parser.parse(markdown)
}
let parseEnd = DispatchTime.now().uptimeNanoseconds

let renderStart = DispatchTime.now().uptimeNanoseconds
var renderedLength = 0
for _ in 0..<iterations {
    let rendered = renderer.render(document)
    renderedLength &+= rendered.plainText.utf16.count
}
let renderEnd = DispatchTime.now().uptimeNanoseconds

let bytes = markdown.utf8.count * iterations
let parseSeconds = Double(parseEnd - parseStart) / 1_000_000_000
let renderSeconds = Double(renderEnd - renderStart) / 1_000_000_000
let parseMBs = Double(bytes) / 1_000_000 / max(parseSeconds, 0.000_001)
let renderMBs = Double(bytes) / 1_000_000 / max(renderSeconds, 0.000_001)

print("fixture_bytes=\(markdown.utf8.count)")
print("blocks=\(document.blocks.count)")
print(String(format: "parse_seconds=%.4f", parseSeconds))
print(String(format: "parse_MBps=%.1f", parseMBs))
print(String(format: "render_seconds=%.4f", renderSeconds))
print(String(format: "render_MBps=%.1f", renderMBs))
print("rendered_length_checksum=\(renderedLength)")

private func argumentValue(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

private func fixture(blocks: Int) -> String {
    var lines: [String] = []
    lines.reserveCapacity(blocks * 7)
    for index in 0..<blocks {
        lines.append("## Heading \(index)")
        lines.append("This is **strong** and *emphasis* with `inline code` plus [a link](https://example.com/\(index)).")
        lines.append("- [x] Parsed task \(index)")
        lines.append("- Nested item with ~~strike~~ and __bold__")
        lines.append("| Metric | Value | Notes |")
        lines.append("| :--- | ---: | :---: |")
        lines.append("| local | \(index) | **pass** |")
        lines.append("| remote | \(index * 2) | `1200x746` |")
        lines.append("> quoted text that should keep inline **styles**")
        lines.append("```swift")
        lines.append("let value\(index) = \"markdown\"")
        lines.append("```")
    }
    return lines.joined(separator: "\n")
}
