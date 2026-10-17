import AppKit
import SwiftUI
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater
@testable import CmuxUpdaterUI

/// Every update popover state must draw inside the popover's width. NSPopover clips at its
/// edge, so content that spills past the body frame loses its first and last letters.
@MainActor
@Suite("Update popover layout", .serialized)
struct UpdatePopoverLayoutTests {
    /// Canvas margin on each side of the popover; any drawing there spilled past the edge.
    private static let margin: CGFloat = 60

    @Test(arguments: LayoutCase.allCases)
    func contentStaysInsidePopoverWidth(_ layoutCase: LayoutCase) throws {
        let model = UpdateStateModel()
        layoutCase.apply(to: model)
        let width = UpdatePopoverView.width(for: model.effectiveState)

        let popover = NSHostingView(rootView: UpdatePopoverView(model: model, actions: LayoutActions()))
        popover.appearance = NSAppearance(named: .darkAqua)
        let height = ceil(popover.fittingSize.height)
        #expect(popover.fittingSize.width == width)

        let canvasWidth = width + Self.margin * 2
        // The popover band gets the popover's background so its text is visible in the saved
        // snapshot; the margins stay transparent.
        let canvas = NSHostingView(rootView: UpdatePopoverView(model: model, actions: LayoutActions())
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: canvasWidth, height: height))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: canvasWidth, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: height)
        canvas.layoutSubtreeIfNeeded()
        canvas.display()
        defer { window.close() }
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        saveSnapshotIfRequested(bitmap, name: layoutCase.rawValue)

        let scale = CGFloat(bitmap.pixelsWide) / canvasWidth
        let leftEdge = Int((Self.margin * scale).rounded(.down)) - 1
        let rightEdge = Int(((Self.margin + width) * scale).rounded(.up)) + 1
        var spilledColumns = 0
        for x in 0..<bitmap.pixelsWide where x < leftEdge || x > rightEdge {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                spilledColumns += 1
                break
            }
        }
        #expect(spilledColumns == 0, "\(layoutCase.rawValue) drew \(spilledColumns) pixel columns outside the popover")
    }

    private func saveSnapshotIfRequested(_ bitmap: NSBitmapImageRep, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["CMUX_UPDATE_POPOVER_SNAPSHOT_DIR"],
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

enum LayoutCase: String, CaseIterable, Sendable {
    case updateAvailable
    case detectedUpdate
    case checking
    case downloading
    case extracting
    case restartRequired
    case heldQuietMoment
    case heldAskingUser
    case heldWaitingForAgents
    case heldSafeAndLongName
    case notFound
    case error

    @MainActor
    func apply(to model: UpdateStateModel) {
        switch self {
        case .updateAvailable:
            model.setState(.updateAvailable(.init(appcastItem: Self.item, reply: { _ in })))
        case .detectedUpdate:
            model.recordDetectedUpdate(Self.item)
        case .checking:
            model.setState(.checking(.init(cancel: {})))
        case .downloading:
            model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 40)))
        case .extracting:
            model.setState(.extracting(.init(progress: 0.5)))
        case .restartRequired:
            model.setState(.installing(.init(retryTerminatingApplication: {}, dismiss: {})))
        case .heldQuietMoment:
            model.setState(.installing(.init(
                isAutoUpdate: true,
                retryTerminatingApplication: {},
                dismiss: {},
                relaunchBlockers: UpdateRelaunchBlockers(agents: [Self.careAgent], runningCommandCount: 0),
                updateWhenClear: {}
            )))
        case .heldAskingUser:
            model.setState(.installing(.init(
                retryTerminatingApplication: {},
                dismiss: {},
                relaunchBlockers: UpdateRelaunchBlockers(
                    agents: [Self.riskyAgent, Self.careAgent],
                    runningCommandCount: 2
                ),
                updateWhenClear: {}
            )))
        case .heldWaitingForAgents:
            model.setState(.installing(.init(
                isAutoUpdate: true,
                retryTerminatingApplication: {},
                dismiss: {},
                relaunchBlockers: UpdateRelaunchBlockers(agents: [Self.riskyAgent, Self.careAgent], runningCommandCount: 0),
                updateWhenClear: {}
            )))
        case .heldSafeAndLongName:
            model.setState(.installing(.init(
                retryTerminatingApplication: {}, dismiss: {},
                relaunchBlockers: UpdateRelaunchBlockers(agents: [
                    UpdateRelaunchAgent(id: "safe", name: "A very long agent workspace name that must wrap safely", location: "workspace", safety: .safe, activity: "Idle"),
                    Self.riskyAgent,
                ], runningCommandCount: 0),
                updateWhenClear: {}
            )))
        case .notFound:
            model.setState(.notFound(.init(acknowledgement: {})))
        case .error:
            model.setState(.error(.init(
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                retry: {},
                dismiss: {},
                technicalDetails: "NSURLErrorDomain(-1009) | feed=https://files.cmux.com/nightly/appcast-arm64.xml"
            )))
        }
    }

    private static var item: SUAppcastItem {
        SUAppcastItem(dictionary: [
            "title": "cmux 0.64.25-nightly.3665317211501",
            "pubDate": "Tue, 29 Sep 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.dmg",
                "length": "143414809",
                "sparkle:version": "3665317211501",
                "sparkle:shortVersionString": "0.64.25-nightly.3665317211501",
            ],
        ]) ?? SUAppcastItem.empty()
    }

    private static let riskyAgent = UpdateRelaunchAgent(
        id: "risky", name: "Claude Code", location: "cmux", safety: .risky,
        activity: "Bash: swift test --filter UpdatePopoverLayoutTests"
    )
    private static let careAgent = UpdateRelaunchAgent(
        id: "care", name: "Codex", location: "hq", safety: .care, activity: "Thinking"
    )
}

@MainActor
private final class LayoutActions: UpdateActionsHost {
    func checkForUpdatesInCustomUI() {}
    func attemptUpdate() {}
    func copyUpdateDetails(_ text: String) -> Bool { true }
    var updateLogPath: String { "~/Library/Logs/cmux-update.log" }
}
