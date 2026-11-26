import AppKit
import Testing
@testable import MessagesLabHome

/// User, 2026-10-30 (screenshot of my outlined quote of a 201-character root over "2 Replies"): "make screenshots of
/// fixing this, handle like multi-multi line". A reply quote's text must wrap inside its outline at every line count
/// and pane width: 1, 2 and 3 lines, a root longer than the quote shows (cut with "…"), a long word and a long URL,
/// on my side and the Chief's. These tests draw each quote with the real row renderer twice, once with its text and
/// once with its lines blank, and read the text's ink from the difference: no ink may reach the outline or past it,
/// and every line must have ink on its own baseline band.
@MainActor @Suite(.serialized) struct ThreadQuoteWrapTests {
    /// The user's root of 2026-10-30, the one in the screenshot.
    static let userRoot = "another thing is i think platonic ideal for multiplayer app store is https://exe.dev/ where you can deploy somewhere and then pin stuff in workspaces, have panes that are remote exe.dev stuff etc"
    /// Five lines in a 628 pt pane.
    static let fiveLines = "Five lines: the reply quote of a long root shows every line of it, wrapped inside its outline the way a Messages bubble wraps. No word runs past the right end, no line is cut off at the left, and the tail still joins the one-line corner at the bottom right. Longer roots stop at eight lines and end in an ellipsis."
    static let texts: [String] = [
        "Reply-to-conversation UI is very bad.",
        userRoot,
        fiveLines,
        // Eight-plus lines in any pane: the quote shows its first lines and ends in "…".
        Array(repeating: "every line of a long root has to stay inside the quote's outline, wrapped and never clipped", count: 8)
            .joined(separator: "\n"),
        // One word longer than any pane's quote column: it breaks inside the word.
        String(repeating: "supercalifragilisticexpialidocious", count: 6),
        "see https://github.com/manaflow-ai/cmux/compare/373339c3030b593d066e5c601eb423b4df64c7e8...4d206505fe4d2f1d41cbab6536ca0a734f7dc2ae?diff=split&w=1 for the diff",
    ]
    static let widths: [CGFloat] = [300, 434, 628, 900, 1240]
    static let scale: CGFloat = 2

    private func preview(_ text: String, outgoing: Bool, width: CGFloat) -> ThreadPreview {
        Fixture.withRenderScale(Self.scale) {
            ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: 2,
                               outgoing: outgoing, width: width)
        }
    }

    /// RGBA bytes of `pv` drawn as the transcript draws it, its box's origin at (`origin`, `origin`).
    private func pixels(_ pv: ThreadPreview, width: CGFloat, origin: CGFloat, light: Bool) -> [UInt8] {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let w = Int((pv.box.width + 2 * origin) * Self.scale), h = Int((pv.box.height + 2 * origin) * Self.scale)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: Self.scale, y: -Self.scale)
            Fixture.withRenderScale(Self.scale) {
                ContextScope.run(ctx) {
                    PartRenderer.drawQuoteBubble(ctx, pv, box: CGRect(x: origin, y: origin, width: pv.box.width, height: pv.box.height))
                }
            }
        }
        return data
    }

    @Test(arguments: [true, false])
    func quoteTextStaysInsideItsOutlineAtEveryWidth(outgoing: Bool) {
        let origin: CGFloat = 10
        for light in [false, true] {
            for width in Self.widths {
                for text in Self.texts {
                    let pv = preview(text, outgoing: outgoing, width: width)
                    let label = "\(outgoing ? "my" : "the Chief's") quote at \(width) pt, \(light ? "light" : "dark"): \(pv.textLines)"
                    #expect(pv.box.height == ThreadPreview.textHeight(lines: pv.textLines.count), "\(label): box \(pv.box)")
                    #expect(pv.textLines.count <= ThreadPreview.maxTextLines, "\(label)")
                    #expect(pv.textLines.allSatisfy { !$0.isEmpty }, "\(label): a blank line")
                    let joined = pv.textLines.joined(separator: " ")
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    if !joined.hasSuffix("…") {
                        // Shown whole: every character of the root is on a line (wrap drops only the spaces it breaks at).
                        #expect(joined.filter { $0 != " " } == flat.filter { $0 != " " }, "\(label): text lost without \"…\"")
                    }
                    let widest = pv.textLines.map { TextDraw.width($0, font: ThreadPreview.textFont) }.max() ?? 0
                    #expect(widest + ThreadPreview.textPadX <= pv.box.width + 0.01, "\(label): widest line \(widest) in a \(pv.box.width) pt box")

                    var blank = pv
                    blank.textLines = pv.textLines.map { _ in "" }
                    let full = pixels(pv, width: width, origin: origin, light: light)
                    let bare = pixels(blank, width: width, origin: origin, light: light)
                    let w = Int((pv.box.width + 2 * origin) * Self.scale)
                    let box = CGRect(x: origin, y: origin, width: pv.box.width, height: pv.box.height)
                    // Inside the 1 pt outline (and half a point of antialiasing): the text's room.
                    let room = box.insetBy(dx: 1, dy: 1)
                    var outside = 0, firstOutside: CGPoint?
                    var perLine = [Int](repeating: 0, count: pv.textLines.count)
                    for i in stride(from: 0, to: full.count, by: 4) {
                        let d = (0..<4).map { abs(Int(full[i + $0]) - Int(bare[i + $0])) }.max() ?? 0
                        guard d > 24 else { continue }
                        let p = CGPoint(x: (CGFloat((i / 4) % w) + 0.5) / Self.scale, y: (CGFloat((i / 4) / w) + 0.5) / Self.scale)
                        if !room.contains(p) {
                            outside += 1
                            if firstOutside == nil { firstOutside = p }
                        }
                        for line in pv.textLines.indices {
                            let baseline = box.minY + ThreadPreview.textFirstBaselineY + ThreadPreview.textLinePitch * CGFloat(line)
                            if p.y > baseline - 8, p.y < baseline + 2.5 { perLine[line] += 1 }
                        }
                    }
                    #expect(outside == 0, "\(label): \(outside) text pixels on or past the outline, first at \(String(describing: firstOutside)) in \(box)")
                    #expect(perLine.allSatisfy { $0 > 0 }, "\(label): a line drew no ink \(perLine)")
                }
            }
        }
    }

    /// "handle like multi-multi line": a root of up to `ThreadPreview.maxTextLines` (8) lines shows whole, every line
    /// of it, with no "…"; a longer root shows 8 lines, the last ending in "…".
    @Test(arguments: [434, 628, 1240] as [CGFloat])
    func aMultiLineRootShowsWholeUpToEightLines(width: CGFloat) {
        for text in [Self.userRoot, Self.fiveLines, Self.userRoot + " " + Self.fiveLines] {
            let pv = preview(text, outgoing: true, width: width)
            let natural = TextLayout.make(text, runs: [], maxWidth: ThreadPreview.maxTextBoxWidth(width: width) - ThreadPreview.textPadX,
                                          font: ThreadPreview.textFont).lines.count
            guard natural <= 8 else { continue }
            #expect(pv.textLines.count == natural, "a \(natural)-line root at \(width) pt shows \(pv.textLines.count) lines: \(pv.textLines)")
            #expect(pv.textLines.last?.hasSuffix("…") == false, "a \(natural)-line root at \(width) pt is cut: \(pv.textLines)")
            #expect(pv.box.height == ThreadPreview.textHeight(lines: natural))
        }
        // The 5-line root is 5 lines in the 628 pt pane (the shots' case).
        if width == 628 { #expect(preview(Self.fiveLines, outgoing: false, width: width).textLines.count == 5) }
        let long = preview(Array(repeating: Self.fiveLines, count: 8).joined(separator: " "), outgoing: false, width: width)
        #expect(long.textLines.count == 8, "\(long.textLines)")
        #expect(long.textLines.last?.hasSuffix("…") == true, "\(long.textLines)")
    }
}
