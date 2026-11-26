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

    /// A press on the card enlarges it at once: live, the release went elsewhere and the card never grew.
    @Test func aPressEnlargesTheCard() throws {
        let card = TerminalComputerUsePreview()
        card.show(Self.card())
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        card.mouseDown(with: press)
        #expect(card.expanded)
        card.mouseDown(with: press)
        #expect(!card.expanded)
    }

    /// Leo, 2026-11-22, asking for "the ability to drag it around and" hide it. The card sits at its
    /// place in the room the pane leaves around it, a drag's place is the inverse, and a move goes
    /// to the App with the session.
    @Test func aMovedCardSitsAtItsPlaceInsideThePane() throws {
        let card = TerminalComputerUsePreview()
        card.area = CGRect(x: 12, y: 12, width: 776, height: 576)
        card.movable = true
        var moves: [TerminalComputerUsePreview.Move] = []
        card.onMove = { session, move in
            #expect(session == "terminal:t1:42")
            moves.append(move)
        }
        card.show(Self.card())
        let size = CGSize(width: 180, height: 112)
        #expect(card.origin(for: size) == CGPoint(x: 608, y: 476), "a new card at the top-trailing corner")
        card.move(.init(x: 0, y: 1))
        #expect(card.origin(for: size) == CGPoint(x: 12, y: 12), "the bottom-leading corner, still inside")
        #expect(moves == [.init(x: 0, y: 1)])
        let middle = card.fractions(of: CGPoint(x: 12 + 298, y: 12 + 232), size: size)
        #expect(abs(middle.x - 0.5) < 0.001 && abs(middle.y - 0.5) < 0.001)
        let outside = card.fractions(of: CGPoint(x: -500, y: 5000), size: size)
        #expect(outside.x == 0 && outside.y == 0, "a drag past the edge stays inside")
    }

    /// The daemon keeps the place: a frame sent before it had the person's move keeps the move, the
    /// echo takes over, and a later place is the daemon's.
    @Test func theDaemonsPlaceTakesOverOnceItEchoesTheMove() {
        let card = TerminalComputerUsePreview()
        var shown = Self.card()
        shown.place = .init()
        card.show(shown)
        card.move(.init(x: 0.25))
        card.show(shown)
        #expect(card.place.x == 0.25, "the frame before the echo keeps the move")
        shown.place = .init(x: 0.25)
        card.show(shown)
        shown.place = .init(x: 0.75, y: 0.5)
        card.show(shown)
        #expect(card.place == .init(x: 0.75, y: 0.5))
        // A daemon that keeps none: the person's own move stays.
        card.move(.init(y: 1))
        var plain = Self.card()
        plain.place = nil
        card.show(plain)
        #expect(card.place.y == 1)
    }

    @Test func closeLeavesTheChipAndTheChipBringsTheCardBack() throws {
        let card = TerminalComputerUsePreview()
        card.movable = true
        var closed: [String] = []
        var shownAgain: [String] = []
        card.onClose = { closed.append($0) }
        card.onShow = { shownAgain.append($0) }
        card.show(Self.card())
        card.perform(NSSelectorFromString("close"))
        #expect(card.collapsed && closed == ["terminal:t1:42"])
        #expect(card.intrinsicContentSize.width < TerminalComputerUsePreview.width, "the chip, not the card")
        // The daemon's hidden card keeps the chip.
        var hidden = Self.card()
        hidden.hidden = true
        card.show(hidden)
        #expect(card.collapsed)
        card.perform(NSSelectorFromString("showAgain"))
        #expect(!card.collapsed && shownAgain == ["terminal:t1:42"])
        #expect(TerminalComputerUsePreview.Card(json: ["session": "s", "frame": Self.frame, "hidden": true,
                                                       "place": ["x": 0, "y": 0.5, "size": "large"]])?.place == .init(x: 0, y: 0.5, size: .large))
    }

    @Test func fullSizeFillsTheRoomAndAClickBringsItBack() {
        let card = TerminalComputerUsePreview()
        card.area = CGRect(x: 12, y: 12, width: 976, height: 500)
        card.movable = true
        var sizes: [TerminalComputerUsePreview.Size?] = []
        card.onMove = { _, move in sizes.append(move.size) }
        card.show(Self.card())
        card.toggleFull()
        #expect(card.full && sizes == [.full])
        #expect(card.intrinsicContentSize.width <= 976 && card.intrinsicContentSize.height <= 500)
        #expect(card.intrinsicContentSize.width > TerminalComputerUsePreview.expandedWidth)
        card.toggleExpanded()
        #expect(card.place.size == .small && sizes == [.full, .small])
    }

    /// Labs > Show Preview Features off (the default): the top right card a click enlarges, with no
    /// drag, no full size and no chip; a close takes it away, and the daemon's place or hidden card is
    /// not drawn.
    @Test func withTheControlsOffTheCardIsTheTopRightOne() {
        let card = TerminalComputerUsePreview()
        card.area = CGRect(x: 12, y: 12, width: 776, height: 576)
        var closed: [String] = []
        card.onClose = { closed.append($0) }
        var placed = Self.card()
        placed.place = .init(x: 0, y: 1, size: .full)
        card.show(placed)
        let size = CGSize(width: 180, height: 112)
        #expect(card.origin(for: size) == CGPoint(x: 608, y: 476), "the top-trailing corner, not the daemon's place")
        #expect(!card.full)
        card.toggleFull()
        #expect(!card.full)
        card.toggleExpanded()
        #expect(card.expanded)
        card.perform(NSSelectorFromString("close"))
        #expect(card.isHidden && card.card == nil && !card.collapsed && closed == ["terminal:t1:42"])
        var hidden = Self.card()
        hidden.hidden = true
        card.show(hidden)
        #expect(card.isHidden && !card.collapsed, "no chip")
        card.movable = true
        #expect(card.collapsed && !card.isHidden, "turned on, the hidden card shows as the chip")
    }
}
