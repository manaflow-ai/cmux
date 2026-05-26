import CMUXMarkdown
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = argumentValue("--out") ?? "/tmp/cmux-markdown-snapshot.png"
let width = argumentValue("--width").flatMap(Int.init) ?? 920
let markdown = """
# Codex transcript markdown

This paragraph has **strong text**, *emphasis*, `inline code`, ~~strikethrough~~, and [links](https://example.com).

## Tool summary

- [x] [AppDelegate.swift](file:///tmp/AppDelegate.swift) renders without coloring the bullet
- [BrowserPanel.swift](file:///tmp/BrowserPanel.swift) renders without coloring the marker
- Kept output selectable in the Codex transcript view
1. [BrowserPanelView.swift](file:///tmp/BrowserPanelView.swift) keeps the number plain

> Context automatically compacted
> The thread is connected, and new messages will stream here.

| Surface | Result | Notes |
| :--- | :---: | ---: |
| Local app | **pass** | 1200x746 |
| Remote host | pass | `cmux-macmini` |
| Escaped \\| pipe | pass | [link](https://example.com) |

```swift
let renderer = CMUXMarkdownCoreTextRenderer()
let text = renderer.render(markdown)
```

------------------------------

1. Headings scale by level
2. Lists preserve indentation
3. Code blocks use the monospaced face
"""

let theme = CMUXMarkdownCoreTextTheme(
    baseFont: CTFontCreateUIFontForLanguage(.system, 16, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, 16, nil),
    monospacedFont: CTFontCreateUIFontForLanguage(.userFixedPitch, 14, nil)
        ?? CTFontCreateWithName("Menlo" as CFString, 14, nil),
    foregroundColor: CGColor(red: 0.92, green: 0.93, blue: 0.90, alpha: 1),
    mutedColor: CGColor(red: 0.56, green: 0.58, blue: 0.54, alpha: 1),
    linkColor: CGColor(red: 0.52, green: 0.68, blue: 1.0, alpha: 1),
    codeColor: CGColor(red: 0.90, green: 0.70, blue: 0.45, alpha: 1),
    paragraphSpacing: 10,
    lineSpacing: 4
)
let rendered = CMUXMarkdownCoreTextRenderer(theme: theme).render(markdown)
let framesetter = CTFramesetterCreateWithAttributedString(rendered.attributedString)
let textWidth = CGFloat(width - 96)
let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
    framesetter,
    CFRange(location: 0, length: 0),
    nil,
    CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
    nil
)
let height = max(420, Int(ceil(suggested.height)) + 96)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Unable to create CGContext")
}

context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.09, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

let path = CGMutablePath()
path.addRect(CGRect(x: 48, y: 48, width: textWidth, height: CGFloat(height - 96)))
let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
CTFrameDraw(frame, context)

guard let image = context.makeImage() else {
    fatalError("Unable to create CGImage")
}
let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Unable to create image destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write PNG")
}
print(outputPath)

private func argumentValue(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}
