import AppKit
import CmuxNextDesign
@testable import CmuxNextServer
import CmuxNextTestSupport
import Foundation
import Testing

/// Renders every state of the Add Server sheet (empty, typing, looking up, not found or expired,
/// words shown, approving, approve failed, added) into one contact sheet, so a fleet run returns the
/// sheet's look as an artifact: `Packages/macOS/CmuxNext/.build/add-server-shots.png`
/// (`cmux-ci run ... --artifact Packages/macOS/CmuxNext/.build/add-server-shots.png`).
/// It also checks that every state draws something at a sane size.
@MainActor @Suite(.serialized, .closesItsWindows) struct AddServerShotsTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyStateRendersToTheContactSheet() throws {
        _ = NSApplication.shared
        var shots: [(String, NSImage)] = []
        for state in AddServerShotState.allCases {
            let source = MockServerSource(scenario: .healthyMac)
            source.echoImmediately = false
            let model = ServerModel(source: source)
            model.start()
            state.drive(model)
            let image = try Self.render(model)
            #expect(image.size.width >= 300, "\(state) is \(image.size.width) pt wide")
            #expect(image.size.height >= 80, "\(state) is \(image.size.height) pt tall")
            shots.append((state.rawValue, image))
        }
        let sheet = Self.contactSheet(shots)
        let out = Self.packageRoot.appending(path: ".build/add-server-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.png(sheet).write(to: out)
        print("add-server-shots: wrote \(out.path)")
    }

    static func render(_ model: ServerModel) throws -> NSImage {
        let view = ServerHostView(model: model, surface: .approver, material: .opaque)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.setContentSize(NSSize(width: max(size.width, 320), height: max(size.height, 120)))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        window.close()
        return image
    }

    static func contactSheet(_ shots: [(String, NSImage)]) -> NSImage {
        let columns = 4, gap: CGFloat = 24, label: CGFloat = 22
        let cellWidth = shots.map(\.1.size.width).max() ?? 0
        let cellHeight = (shots.map(\.1.size.height).max() ?? 0) + label
        let rows = (shots.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * (cellWidth + gap) + gap, height: CGFloat(rows) * (cellHeight + gap) + gap)
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, shot) in shots.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (cellWidth + gap)
            let top = size.height - gap - CGFloat(row) * (cellHeight + gap)
            (shot.0 as NSString).draw(at: NSPoint(x: x, y: top - 16), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: TypeScale.detail, weight: TypeScale.regular),
                .foregroundColor: NSColor(white: 0.85, alpha: 1),
            ])
            shot.1.draw(in: NSRect(x: x, y: top - label - shot.1.size.height, width: shot.1.size.width, height: shot.1.size.height))
        }
        sheet.unlockFocus()
        return sheet
    }

    static func png(_ image: NSImage) throws -> Data {
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

/// The states the contact sheet shows, each reached through the model as the app reaches it.
enum AddServerShotState: String, CaseIterable {
    case empty = "1 empty"
    case typing = "2 typing"
    case lookingUp = "3 looking up"
    case notFound = "4 not found / expired"
    case review = "5 words shown"
    case approving = "6 approving"
    case approveFailed = "7 approve failed"
    case added = "8 added"

    static let missingCode = "ZZZZ-ZZZZ"

    @MainActor func drive(_ model: ServerModel) {
        switch self {
        case .empty:
            break
        case .typing:
            model.setApprovalCode("7KQ4")
        case .lookingUp:
            model.setApprovalCode(MockServerScenario.offerCode)
        case .notFound:
            model.setApprovalCode(Self.missingCode)
            settleLast(model, reject: "No server is waiting with that code.")
        case .review:
            found(model)
        case .approving:
            found(model)
            model.approve()
        case .approveFailed:
            found(model)
            model.approve()
            settleLast(model, reject: "Could not reach cmux. Check the connection and try again.")
        case .added:
            found(model)
            model.approve()
            settleLast(model, reject: nil)
        }
    }

    @MainActor private func found(_ model: ServerModel) {
        model.setApprovalCode(MockServerScenario.offerCode)
        model.handle(.candidate(MockServerScenario.candidate))
        settleLast(model, reject: nil)
    }

    @MainActor private func settleLast(_ model: ServerModel, reject: String?) {
        guard let key = model.pending.last?.key else { return }
        model.handle(.settled(key: key, reject: reject))
    }
}
