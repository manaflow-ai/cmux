import AppKit
import CmuxAgentQuestion
@testable import CmuxNextAgentQuestion
import Testing

/// Renders every question card variant (each shared fixture, plus
/// interaction states) in light and dark at three widths, offscreen. Each
/// picture must be non-empty. With `CMUX_QUESTION_CARD_SNAPSHOT_DIR` set it
/// also writes the PNGs and an index.html there (dogfood evidence; the UI
/// Gallery owns the general screen).
@MainActor
@Suite struct AgentQuestionCardSnapshotTests {
    struct Variant {
        var name: String
        var fixture: String
        var inputs: [AgentQuestionCardState.Input] = []
    }

    static let variants: [Variant] = AgentQuestionFixture.names.map { Variant(name: $0, fixture: $0) } + [
        Variant(name: "pending-single-highlighted", fixture: "pending-single", inputs: [.down]),
        Variant(name: "pending-multi-two-chosen", fixture: "pending-multi", inputs: [.number(1), .number(4), .down]),
        Variant(name: "pending-other-typing-draft", fixture: "pending-other-typing", inputs: [.number(4), .otherText("Mutual TLS with short-lived certs")]),
        Variant(name: "pending-with-preview-third", fixture: "pending-with-preview", inputs: [.down, .down]),
        Variant(name: "pending-4-questions-second", fixture: "pending-4-questions", inputs: [.number(2)]),
    ]

    @Test func everyVariantRendersInBothAppearancesAtEveryWidth() throws {
        let directory = ProcessInfo.processInfo.environment["CMUX_QUESTION_CARD_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var entries: [(variant: String, file: String, appearance: String, width: Int)] = []
        for variant in Self.variants {
            let question = try AgentQuestionFixture(name: variant.fixture).question
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for width in [320, 560, 900] {
                    let png = try #require(Self.render(question, inputs: variant.inputs, width: CGFloat(width), appearance: appearance),
                                           "\(variant.name) \(appearance.rawValue) \(width)")
                    #expect(png.count > 1000, "\(variant.name) \(appearance.rawValue) \(width)")
                    let mode = appearance == .darkAqua ? "dark" : "light"
                    let file = "\(variant.name)--\(mode)--\(width).png"
                    if let directory { try png.write(to: directory.appendingPathComponent(file)) }
                    entries.append((variant.name, file, mode, width))
                }
            }
        }
        if let directory {
            try Self.index(entries).write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        }
    }

    /// The card drawn into a bitmap at 2x, on the window background color.
    static func render(_ question: AgentQuestion, inputs: [AgentQuestionCardState.Input], width: CGFloat,
                       appearance: NSAppearance.Name) -> Data? {
        let card = AgentQuestionCardView()
        card.appearance = NSAppearance(named: appearance)
        card.configure(question: question, width: width - 32)
        card.replayForPreview(inputs)
        let height = card.currentHeight
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 32))
        host.appearance = NSAppearance(named: appearance)
        host.wantsLayer = true
        host.addSubview(card)
        card.frame = NSRect(x: 16, y: 16, width: width - 32, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layer?.backgroundColor = appearance == .darkAqua
            ? NSColor(white: 0.11, alpha: 1).cgColor : NSColor(white: 0.97, alpha: 1).cgColor
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scale: CGFloat = 2
        guard let layer = host.layer,
              let context = CGContext(data: nil, width: Int(host.bounds.width * scale), height: Int(host.bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, // crash-allow: sRGB always exists
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            layer.render(in: context)
        }
        window.close()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A plain HTML page that shows every picture, grouped by variant.
    static func index(_ entries: [(variant: String, file: String, appearance: String, width: Int)]) -> String {
        var html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Question card variants</title>
        <style>body{font:14px -apple-system,sans-serif;margin:24px;background:#888;color:#111}
        h2{margin:32px 0 8px}figure{display:inline-block;margin:0 16px 16px 0;vertical-align:top}
        figcaption{font-size:12px;color:#222}img{display:block;border-radius:8px}</style></head><body>
        <h1>Question card variants</h1>
        """
        var current = ""
        for entry in entries {
            if entry.variant != current {
                current = entry.variant
                html += "<h2 id=\"\(current)\">\(current)</h2>\n"
            }
            html += "<figure><img src=\"\(entry.file)\" width=\"\(entry.width)\" alt=\"\(entry.variant) \(entry.appearance) \(entry.width)\">"
            html += "<figcaption>\(entry.appearance) · \(entry.width) pt</figcaption></figure>\n"
        }
        return html + "</body></html>\n"
    }
}
