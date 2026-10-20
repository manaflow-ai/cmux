#if canImport(AppKit)
import AppKit
@testable import CmuxMobileAgentChat
import SwiftUI
import Testing

/// Chat-feed review F3: at AX5 the transcript was measured taller than it drew, which left
/// a blank band above the composer. Measured and drawn heights must match for every row
/// type, including a row that cannot shrink to the column (the answer action row's icons).
@MainActor
@Suite struct TranscriptHeightTests {
    private static let column: CGFloat = 362
    private static let prose = String(repeating: "The transport underneath never sees channels, so WireGuard can share it. ", count: 6)

    /// Row frames as drawn, by name.
    @MainActor final class Frames {
        var byName: [String: CGRect] = [:]
    }

    /// One row of each kind the transcript draws, at their AX5 shapes.
    @ViewBuilder
    private static func row(_ kind: String) -> some View {
        switch kind {
        case "markdown":
            Text(prose).frame(maxWidth: .infinity, alignment: .leading)
        case "tool":
            HStack(spacing: 8) { Image(systemName: "doc.text"); Text("Read"); Text("frame.rs").lineLimit(1); Spacer(minLength: 0) }
        case "question":
            VStack(alignment: .leading, spacing: 8) {
                Text("Which transport should be the default on cellular?").font(.headline)
                ForEach(["WebRTC", "WireGuard", "Other…"], id: \.self) { Text($0).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
            }
        case "plan":
            VStack(alignment: .leading, spacing: 4) {
                ForEach(["Add TransportKind", "Route LinkDialer", "Run the tests"], id: \.self) { Label($0, systemImage: "circle") }
            }
        case "image":
            Color.gray.frame(width: 200, height: 150).frame(maxWidth: .infinity, alignment: .trailing)
        default:
            // The answer action row at AX5: four 90 pt targets and a duration, wider than the column.
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in Color.clear.frame(width: 90, height: 90) }
                Spacer()
                Text("25m 7s").fixedSize()
            }
        }
    }

    private static let kinds = ["markdown", "tool", "question", "plan", "image", "actions", "markdown"]

    private func transcript(clamped: Bool, frames: Frames) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(Self.kinds.enumerated()), id: \.offset) { index, kind in
                Group {
                    if clamped {
                        ProposedWidthLayout { Self.row(kind) }
                    } else {
                        Self.row(kind)
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("transcript")) }) { frames.byName["\(index)-\(kind)"] = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named("transcript"))
        .dynamicTypeSize(.accessibility5)
    }

    /// The transcript's measured height at the column width, and its rows as drawn at that size.
    private func measureAndDraw(clamped: Bool) -> (measured: CGFloat, frames: [String: CGRect]) {
        let frames = Frames()
        let host = NSHostingView(rootView: ProposedWidthLayout { transcript(clamped: clamped, frames: frames) }
            .fixedSize(horizontal: false, vertical: true))
        let measured = host.fittingSize(width: Self.column)
        host.frame = CGRect(x: 0, y: 0, width: Self.column, height: measured)
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (measured, frames.byName)
    }

    @Test func everyRowIsDrawnAtTheColumnWidthAndTheHeightItWasMeasuredAt() {
        let (measured, frames) = measureAndDraw(clamped: true)
        #expect(frames.count == Self.kinds.count)
        for (name, frame) in frames {
            #expect(abs(frame.width - Self.column) < 0.5, "\(name) drawn \(frame.width) pt wide")
        }
        let drawnBottom = frames.values.map(\.maxY).max() ?? 0
        #expect(abs(drawnBottom - measured) < 1, "measured \(measured), drawn \(drawnBottom)")
    }

    @Test func anUnclampedWideRowWidensEveryRow() {
        // The regression this guards: without the clamp the action row widens the column.
        let (_, frames) = measureAndDraw(clamped: false)
        let markdown = frames.first { $0.key.hasSuffix("markdown") }?.value
        #expect((markdown?.width ?? 0) > Self.column + 1)
    }
}

private extension NSHostingView {
    func fittingSize(width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: rootView)
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
#endif

