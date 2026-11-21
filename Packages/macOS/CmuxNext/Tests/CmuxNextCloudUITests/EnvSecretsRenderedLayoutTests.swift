#if DEBUG
import AppKit
@testable import CmuxNextCloudUI
import SwiftUI
import Testing
import Vision

/// Environment Secrets Playground, checked on the drawn pixels: each direction is hosted in an
/// `NSHostingView` the size of the playground window, drawn into a bitmap, and read back with on-device
/// text recognition. The tests use only the model and the direction views, so they compile on the
/// gallery before its fix and fail there on the drawn result.
@MainActor @Suite struct EnvSecretsRenderedLayoutTests {
    /// Ledger, History state: the open row's history starts one indent in from the row's left edge.
    /// Before the fix the history was centred under the row, about 255 points to the right.
    @Test func ledgerHistoryStartsAtTheRowsLeftEdge() throws {
        let model = EnvSecretsPlaygroundModel()
        model.scene = .audit
        let page = try RenderedPage(EnvLedgerDirection(model: model))
        let nameColumn = try #require(page.line("Name"), "the table's Name column title is drawn")
        let firstUse = try #require(page.line(containing: "4:07 PM"), "the history's first line is drawn")
        #expect(firstUse.minX - nameColumn.minX < 40, "history starts \(firstUse.minX - nameColumn.minX) pt right of the Name column")
    }

    /// Sentences, Agent asks state: the request card offers Chat, Personal and Team under "Where to keep
    /// it", Chat is the picked one (the filled accent radio), and the save button says so.
    @Test func sentencesRequestCardOffersTheScopeChoiceWithChatPicked() throws {
        let model = EnvSecretsPlaygroundModel()
        model.scene = .request
        let page = try RenderedPage(EnvSentencesDirection(model: model))
        #expect(page.line("Where to keep it") != nil, "the card has the \"Where to keep it\" title")
        let chat = try #require(page.line(containing: "Only this chat"), "the Chat choice is drawn")
        let personal = try #require(page.line(containing: "Only you."), "the Personal choice is drawn")
        let team = try #require(page.line(containing: "Needs an admin's Touch ID"), "the Team choice is drawn")
        #expect(page.accentPixels(leftOf: chat) > 0, "the Chat radio is filled")
        #expect(page.accentPixels(leftOf: personal) == 0, "the Personal radio is empty")
        #expect(page.accentPixels(leftOf: team) == 0, "the Team radio is empty")
        #expect(page.line("Save for this chat") != nil, "the save button keeps the value for this chat")
    }
}

/// One direction drawn at the playground window's size in the light look, with its recognised text
/// lines in view points (origin top left).
@MainActor
private struct RenderedPage: CustomStringConvertible {
    let bitmap: NSBitmapImageRep
    let lines: [(text: String, frame: CGRect)]
    let scale: CGFloat

    init(_ view: some View) throws {
        _ = NSApplication.shared
        let size = CGSize(width: 1180, height: 820)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        self.bitmap = bitmap
        self.scale = CGFloat(bitmap.pixelsWide) / size.width
        self.lines = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                 width: box.width * size.width, height: box.height * size.height))
        }
    }

    /// The recognised lines, for a failed expectation's message.
    var description: String { lines.map(\.text).joined(separator: " | ") }

    /// The frame of the line that reads exactly `text`.
    func line(_ text: String) -> CGRect? { lines.first { $0.text == text }?.frame }

    /// The frame of the first line that contains `text`.
    func line(containing text: String) -> CGRect? { lines.first { $0.text.contains(text) }?.frame }

    /// Strongly blue (accent) pixels in the 40 points left of `line`, from one line above it to its
    /// bottom: where a choice's radio is drawn.
    func accentPixels(leftOf line: CGRect) -> Int {
        let rows = Int((line.minY - line.height * 1.6) * scale)..<Int(line.maxY * scale)
        let columns = Int((line.minX - 40) * scale)..<Int(line.minX * scale)
        var count = 0
        for y in rows { for x in columns {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.blueComponent > 0.75, color.redComponent < 0.35, color.greenComponent < 0.65 { count += 1 }
        } }
        return count
    }
}
#endif
