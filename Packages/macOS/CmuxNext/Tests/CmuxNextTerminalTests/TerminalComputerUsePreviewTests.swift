import AppKit
@testable import CmuxNextTerminal
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Computer Use's live preview card in a terminal pane: it shows a running card's frame, enlarges on
/// a click and back, hides on close (telling the App the session), and sits at the pane's
/// top-trailing corner. Before, a terminal pane had no preview at all.
@MainActor
struct TerminalComputerUsePreviewTests {
    /// A 40x25 JPEG frame as the worker sends it.
    static let frame: String = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 40, height: 25, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 25))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }()

    static func card(done: Bool = false, session: String = "terminal:t1:42") -> TerminalComputerUsePreview.Card {
        TerminalComputerUsePreview.Card(session: session, app: "Calculator", done: done, frame: frame,
                                        pointer: CGPoint(x: 0.5, y: 0.25), clicks: 2)
    }

    @Test func aCardDecodesFromTheWorkersLine() throws {
        let json: [String: Any] = ["session": "terminal:t1:42", "label": "Claude Code", "app": "Calculator", "done": false,
                                   "frame": Self.frame, "pointer": ["x": 0.5, "y": 0.25, "click": 3, "windowWidth": 400]]
        let card = try #require(TerminalComputerUsePreview.Card(json: json))
        #expect(card.app == "Calculator" && !card.done && card.pointer == CGPoint(x: 0.5, y: 0.25) && card.clicks == 3)
        #expect(TerminalComputerUsePreview.Card(json: ["session": "s", "frame": "https://example.com/x.jpg"]) == nil)
        #expect(TerminalComputerUsePreview.image(fromDataURL: Self.frame)?.width == 40)
    }

    @Test func aCardShowsOnceItsFrameDecodedEnlargesAndCloses() async throws {
        let host = TerminalHostView()
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let card = TerminalComputerUsePreview()
        host.computerUsePreview = card
        var closed: [String] = []
        card.onClose = { closed.append($0) }
        card.show(Self.card())
        // The frame decodes off the main thread; the card shows once it has.
        for _ in 0..<200 where card.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!card.isHidden)
        host.layoutSubtreeIfNeeded()
        #expect(card.frame.width == TerminalComputerUsePreview.width)
        #expect(abs(card.frame.height - 112.5) <= 1) // 40x25 at 180 wide
        #expect(card.frame.maxY > host.bounds.height - 40 && card.frame.maxX > host.bounds.width - 60) // top-trailing
        card.toggleExpanded()
        host.layoutSubtreeIfNeeded()
        #expect(card.frame.width == TerminalComputerUsePreview.expandedWidth)
        card.toggleExpanded()
        host.layoutSubtreeIfNeeded()
        #expect(card.frame.width == TerminalComputerUsePreview.width)
        // Done keeps the frame; a new session's card starts small.
        card.toggleExpanded()
        card.show(Self.card(done: true))
        #expect(card.expanded && !card.isHidden)
        card.show(Self.card(session: "terminal:t1:43"))
        #expect(!card.expanded)
        // Gone (the window closed, the preview turned off).
        card.show(nil)
        #expect(card.isHidden && card.card == nil)
        #expect(closed.isEmpty)
    }
}
