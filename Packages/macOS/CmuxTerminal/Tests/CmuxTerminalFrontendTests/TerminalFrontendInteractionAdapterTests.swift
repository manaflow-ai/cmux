import AppKit
import CoreGraphics
@testable import CmuxTerminalFrontend
import Foundation
import Testing

@MainActor
@Suite struct TerminalFrontendInteractionAdapterTests {
    @Test func leftPointerSequenceUsesBackingPixelsModifiersAndBoundedClickCount() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot(backingScale: 2)
        let mounted = mountView(runtime: runtime)
        let view = mounted.view

        view.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 65, y: 50),
            window: mounted.window,
            modifierFlags: [.shift, .command],
            clickCount: 7
        ))
        view.mouseDragged(with: try mouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: 25, y: 135),
            window: mounted.window,
            modifierFlags: [.option],
            clickCount: 7
        ))
        view.mouseUp(with: try mouseEvent(
            type: .leftMouseUp,
            location: NSPoint(x: 25, y: 135),
            window: mounted.window,
            clickCount: 7
        ))

        #expect(runtime.mutations == [
            .focus(true),
            .mouse(TerminalExternalMouseEvent(
                action: .press,
                button: .left,
                modifiers: [.shift, .command],
                xPixels: 50,
                yPixels: 140,
                anyButtonPressed: true,
                clickCount: 3
            )),
            .mouse(TerminalExternalMouseEvent(
                action: .motion,
                button: .left,
                modifiers: [.option],
                xPixels: -30,
                yPixels: -30,
                anyButtonPressed: true,
                clickCount: 3
            )),
            .mouse(TerminalExternalMouseEvent(
                action: .release,
                button: .left,
                modifiers: [],
                xPixels: -30,
                yPixels: -30,
                anyButtonPressed: false,
                clickCount: 3
            )),
        ])
    }

    @Test func pointerHoverRoutesOnlyForBackendMouseTracking() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot(mouseTracking: false)
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            runtime: runtime
        )
        let event = try mouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: 20, y: 30),
            modifierFlags: [.control]
        )

        view.mouseMoved(with: event)
        #expect(runtime.mutations.isEmpty)

        runtime.snapshot = runtimeSnapshot(mouseTracking: true)
        view.mouseMoved(with: event)

        #expect(runtime.mutations == [
            .mouse(TerminalExternalMouseEvent(
                action: .motion,
                button: nil,
                modifiers: [.control],
                xPixels: 20,
                yPixels: 70,
                anyButtonPressed: false
            )),
        ])
    }

    @Test func rejectedPointerPressCannotDragReleaseOrRetry() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot()
        runtime.stubbedIngressResults = [.rejected(.queueFull)]
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            runtime: runtime
        )
        let down = try mouseEvent(type: .leftMouseDown, location: .zero)
        let drag = try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: -10, y: 110))
        let up = try mouseEvent(type: .leftMouseUp, location: NSPoint(x: -10, y: 110))

        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        view.cancelPointerInteractions()

        #expect(runtime.mutations.count == 1)
        #expect(view.lastIngressResult == .rejected(.queueFull))
        guard case .mouse(let event)? = runtime.mutations.first else {
            Issue.record("Expected one rejected pointer press")
            return
        }
        #expect(event.action == .press)
        #expect(event.button == .left)
    }

    @Test func pointerCancellationReleasesEachAdmittedButtonExactlyOnce() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot(mouseTracking: true)
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            runtime: runtime
        )

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 10, y: 20)))
        view.rightMouseDown(with: try mouseEvent(type: .rightMouseDown, location: NSPoint(x: 30, y: 40)))
        view.cancelPointerInteractions()
        view.cancelPointerInteractions()
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 50, y: 60)))
        view.rightMouseUp(with: try mouseEvent(type: .rightMouseUp, location: NSPoint(x: 50, y: 60)))

        let mouseEvents = runtime.mutations.compactMap { mutation -> TerminalExternalMouseEvent? in
            guard case .mouse(let event) = mutation else { return nil }
            return event
        }
        #expect(mouseEvents.map(\.action) == [.press, .press, .release, .release])
        #expect(mouseEvents.map(\.button) == [.left, .right, .left, .right])
        #expect(mouseEvents[2].anyButtonPressed)
        #expect(!mouseEvents[3].anyButtonPressed)
        #expect(mouseEvents[2].xPixels == 30)
        #expect(mouseEvents[2].yPixels == 60)
    }

    @Test func nonpreciseScrollUsesLineUnitsAndPhaseEndAddsNoMutation() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot()
        let view = TerminalFrontendInteractionView(runtime: runtime)

        view.scrollWheel(with: try scrollEvent(
            deltaY: 4,
            units: .line,
            phase: .began
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: -2,
            units: .line,
            phase: .changed
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 0,
            units: .line,
            phase: .ended
        ))

        #expect(runtime.mutations == [
            .scroll(operation: .lines, amount: -4),
            .scroll(operation: .lines, amount: 2),
        ])
    }

    @Test func preciseScrollCarriesRemainderIntoMomentumAndClearsItOnCancellation() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot(cellHeightPixels: 20, backingScale: 2)
        let view = TerminalFrontendInteractionView(runtime: runtime)

        view.scrollWheel(with: try scrollEvent(
            deltaY: 4,
            units: .pixel,
            phase: .began
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 0,
            units: .pixel,
            phase: .ended,
            momentumPhase: .mayBegin
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 4,
            units: .pixel,
            momentumPhase: .began
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 3,
            units: .pixel,
            momentumPhase: .changed
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 0,
            units: .pixel,
            momentumPhase: .ended
        ))

        view.scrollWheel(with: try scrollEvent(
            deltaY: 8,
            units: .pixel,
            phase: .began
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 0,
            units: .pixel,
            phase: .cancelled
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 3,
            units: .pixel,
            phase: .began
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 7,
            units: .pixel,
            phase: .changed
        ))

        #expect(runtime.mutations == [
            .scroll(operation: .lines, amount: -1),
            .scroll(operation: .lines, amount: -1),
            .scroll(operation: .lines, amount: -1),
        ])
    }

    @Test func trackedScrollUsesDominantWheelAxisAndStopsAtItsFixedCeiling() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot(mouseTracking: true)
        let view = TerminalFrontendInteractionView(runtime: runtime)

        view.scrollWheel(with: try scrollEvent(
            deltaX: -40,
            deltaY: 10,
            units: .pixel,
            phase: .changed
        ))

        #expect(runtime.mutations.count == 32)
        #expect(runtime.mutations.allSatisfy { mutation in
            guard case .mouse(let event) = mutation else { return false }
            return event.action == .press
                && event.button == .wheelRight
                && event.anyButtonPressed
                && event.clickCount == 1
        })
    }

    @Test func semanticCommandsAreOrderedAndBoundTheirRetainedPayloads() {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(runtime: runtime)
        let oversizedQuery = String(repeating: "😀", count: 20_000)

        view.performSelection(.selectAll)
        view.performCopyMode(.adjust, adjustment: .right, count: .max)
        view.performCopyMode(.enter, adjustment: .left, count: 0)
        view.performSearch(.start, query: oversizedQuery)
        view.performSearch(.next, query: oversizedQuery)
        view.performScroll(.lines, amount: .max)
        view.performScroll(.top, amount: 42)

        #expect(runtime.mutations.count == 7)
        #expect(runtime.mutations[0] == .selection(.selectAll))
        #expect(runtime.mutations[1] == .copyMode(
            operation: .adjust,
            adjustment: .right,
            count: TerminalFrontendInteractionView.maximumCommandCount
        ))
        #expect(runtime.mutations[2] == .copyMode(
            operation: .enter,
            adjustment: nil,
            count: 1
        ))
        guard case .search(operation: .start, query: let query?) = runtime.mutations[3] else {
            Issue.record("Expected bounded search-start mutation")
            return
        }
        #expect(query.utf8.count <= TerminalFrontendInteractionView.maximumSearchQueryUTF8Length)
        #expect(oversizedQuery.hasPrefix(query))
        #expect(runtime.mutations[4] == .search(operation: .next, query: nil))
        #expect(runtime.mutations[5] == .scroll(
            operation: .lines,
            amount: Int64(TerminalFrontendInteractionView.maximumCommandCount)
        ))
        #expect(runtime.mutations[6] == .scroll(operation: .top, amount: nil))
    }

    @Test func clipboardRequestReadsCanonicalSelectionAndWritesNoEmptyValue() async {
        let runtime = FakeTerminalExternalRuntime()
        let clipboard = RecordingTerminalClipboardWriter()
        let view = TerminalFrontendInteractionView(
            frame: .zero,
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero),
            clipboardWriter: clipboard,
            keyEventInterpreter: nil
        )

        #expect(await view.copySelectionToClipboard())
        #expect(runtime.selectionReadCount == 1)
        #expect(clipboard.values == ["selected"])

        runtime.stubbedSelection = TerminalExternalSelection(
            text: "",
            start: TerminalExternalCellPoint(column: 0, row: 0),
            end: TerminalExternalCellPoint(column: 0, row: 0),
            topLeft: TerminalExternalCellPoint(column: 0, row: 0),
            bottomRight: TerminalExternalCellPoint(column: 0, row: 0),
            rectangle: false
        )
        #expect(!(await view.copySelectionToClipboard()))
        #expect(runtime.selectionReadCount == 2)
        #expect(clipboard.values == ["selected"])
    }

    @Test func accessibilityAdaptersUseCurrentSnapshotAsAnActivationFence() async throws {
        let current = accessibilitySnapshot(contentSequence: 7, target: "https://example.com/current")
        let stale = accessibilitySnapshot(contentSequence: 6, target: "https://example.com/stale")
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = runtimeSnapshot(accessibility: current)
        runtime.stubbedAccessibilitySnapshots = [current]
        let view = TerminalFrontendInteractionView(runtime: runtime)

        #expect(view.terminalAccessibilitySnapshot == current)
        view.enableTerminalAccessibility()
        #expect(runtime.accessibilityEnableCount == 1)

        var snapshots = view.terminalAccessibilitySnapshots().makeAsyncIterator()
        #expect(await snapshots.next() == current)
        #expect(await snapshots.next() == nil)

        let staleTarget = await view.activateTerminalAccessibilityLink(
            try #require(stale.links.first),
            snapshot: stale
        )
        #expect(staleTarget == nil)
        #expect(runtime.accessibilityLinkActivations.isEmpty)

        let currentLink = try #require(current.links.first)
        let target = await view.activateTerminalAccessibilityLink(
            currentLink,
            snapshot: current
        )
        #expect(target == currentLink.target)
        #expect(runtime.accessibilityLinkActivations.count == 1)
        #expect(runtime.accessibilityLinkActivations[0].link == currentLink)
        #expect(runtime.accessibilityLinkActivations[0].snapshot == current)
    }

    @Test func wholeFrontendTargetStaysFreeOfLegacyTerminalAndGhosttyImports() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/CmuxTerminalFrontend")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        let sourceURLs = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "swift"
        }

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let importedModules = source.split(separator: "\n").compactMap { line -> String? in
                let tokens = line.split(whereSeparator: \.isWhitespace)
                guard let importIndex = tokens.firstIndex(of: "import") else { return nil }
                let moduleIndex = tokens.index(after: importIndex)
                guard moduleIndex < tokens.endIndex else { return nil }
                return String(tokens[moduleIndex])
            }
            #expect(!importedModules.contains("CmuxTerminal"), "\(sourceURL.lastPathComponent)")
            #expect(
                !importedModules.contains { $0.hasPrefix("Ghostty") },
                "\(sourceURL.lastPathComponent)"
            )
        }
    }

    private func runtimeSnapshot(
        mouseTracking: Bool = false,
        cellHeightPixels: Int = 20,
        backingScale: Double = 1,
        accessibility: TerminalAccessibilitySnapshot? = nil
    ) -> TerminalExternalRuntimeSnapshot {
        TerminalExternalRuntimeSnapshot(
            lifecycle: .live,
            cellMetrics: TerminalExternalCellMetrics(
                columns: 20,
                rows: 10,
                cellWidthPixels: 10,
                cellHeightPixels: cellHeightPixels,
                surfaceWidthPixels: 200,
                surfaceHeightPixels: 200,
                backingScale: backingScale
            ),
            mouseTracking: mouseTracking,
            accessibility: accessibility
        )
    }

    private func accessibilitySnapshot(
        contentSequence: UInt64,
        target: String
    ) -> TerminalAccessibilitySnapshot {
        TerminalAccessibilitySnapshot(
            schemaVersion: 1,
            surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            presentationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            presentationGeneration: 3,
            contentSequence: contentSequence,
            terminalRevision: contentSequence,
            contentRevision: contentSequence,
            viewportRevision: 4,
            viewportOffset: 0,
            columns: 20,
            rows: 10,
            text: "link",
            lines: [],
            cursor: nil,
            selections: [],
            links: [TerminalAccessibilityLink(
                id: "link-\(contentSequence)",
                target: target,
                utf16Range: TerminalAccessibilityRange(location: 0, length: 4),
                row: 0,
                startColumn: 0,
                endColumn: 4
            )],
            focused: true
        )
    }

    private func mountView(
        runtime: FakeTerminalExternalRuntime
    ) -> (window: NSWindow, view: TerminalFrontendInteractionView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 40, y: 20, width: 200, height: 100),
            runtime: runtime
        )
        container.addSubview(view)
        return (window, view)
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow? = nil,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: 1,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private func scrollEvent(
        deltaX: Int32 = 0,
        deltaY: Int32,
        units: CGScrollEventUnit,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ))
        if units == .pixel {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase.rawValue)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(momentumPhase.rawValue)
        )
        return try #require(NSEvent(cgEvent: event))
    }
}

@MainActor
private final class RecordingTerminalClipboardWriter: TerminalFrontendClipboardWriting {
    private(set) var values: [String] = []

    func writeTerminalText(_ text: String) -> Bool {
        values.append(text)
        return true
    }
}
