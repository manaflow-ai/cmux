import AppKit
@testable import CmuxTerminalFrontend
import Dispatch
import Testing

@MainActor
@Suite struct TerminalFrontendAccessibilityTests {
    @Test func UTF16TextProjectionPreservesComposedCharactersLinesAndCells() {
        let snapshot = makeAccessibilitySnapshot(
            contentSequence: 7,
            text: "🙂e\u{301}界",
            lines: [TerminalAccessibilityLine(
                row: 40,
                utf16Range: TerminalAccessibilityRange(location: 0, length: 5),
                cells: [
                    TerminalAccessibilityCell(
                        column: 0,
                        columnSpan: 2,
                        utf16Range: TerminalAccessibilityRange(location: 0, length: 2)
                    ),
                    TerminalAccessibilityCell(
                        column: 2,
                        columnSpan: 1,
                        utf16Range: TerminalAccessibilityRange(location: 2, length: 2)
                    ),
                    TerminalAccessibilityCell(
                        column: 3,
                        columnSpan: 2,
                        utf16Range: TerminalAccessibilityRange(location: 4, length: 1)
                    ),
                ]
            )],
            cursor: TerminalAccessibilityCursor(
                column: 2,
                row: 40,
                insertionRange: TerminalAccessibilityRange(location: 2, length: 0),
                line: 0
            ),
            selections: []
        )
        let model = TerminalFrontendAccessibilityTextModel(snapshot: snapshot)

        #expect(model.utf16Length == 5)
        #expect(model.string(for: NSRange(location: 0, length: 2)) == "🙂")
        #expect(model.composedRange(for: 0) == NSRange(location: 0, length: 2))
        #expect(model.line(for: 4) == 0)
        #expect(model.range(forLine: 0) == NSRange(location: 0, length: 5))
        #expect(model.range(viewportRow: 0, column: 1) == NSRange(location: 0, length: 2))
        #expect(
            model.cells(intersecting: NSRange(location: 2, length: 2)).map(\.column)
                == [2]
        )
        #expect(
            model.cells(intersecting: NSRange(location: 2, length: 0)).map(\.column)
                == [2]
        )
        #expect(model.selectedRange == NSRange(location: 2, length: 0))
        #expect(model.string(for: NSRange(location: 5, length: 1)) == nil)
    }

    @Test func AXReadsShareOneDemandAndExposeCanonicalTextAttributes() throws {
        let selection = TerminalAccessibilitySelection(
            text: "e\u{301}",
            utf16Ranges: [TerminalAccessibilityRange(location: 2, length: 2)]
        )
        let snapshot = makeAccessibilitySnapshot(
            contentSequence: 8,
            text: "🙂e\u{301}界",
            lines: [TerminalAccessibilityLine(
                row: 40,
                utf16Range: TerminalAccessibilityRange(location: 0, length: 5),
                cells: []
            )],
            cursor: TerminalAccessibilityCursor(
                column: 2,
                row: 40,
                insertionRange: TerminalAccessibilityRange(location: 2, length: 0),
                line: 0
            ),
            selections: [selection]
        )
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = makeRuntimeSnapshot(accessibility: snapshot)
        runtime.stubbedAccessibilitySnapshots = [snapshot]
        let view = TerminalFrontendInteractionView(runtime: runtime)
        let window = mount(view)

        #expect(window.contentView === view)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityValue() as? String == snapshot.text)
        #expect(view.accessibilityNumberOfCharacters() == 5)
        #expect(view.accessibilityVisibleCharacterRange() == NSRange(location: 0, length: 5))
        #expect(view.accessibilitySelectedText() == selection.text)
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 2, length: 2))
        #expect(
            view.accessibilitySelectedTextRanges()?.map(\.rangeValue)
                == [NSRange(location: 2, length: 2)]
        )
        #expect(view.accessibilityInsertionPointLineNumber() == 0)
        #expect(view.accessibilityString(for: NSRange(location: 0, length: 2)) == "🙂")
        #expect(view.accessibilityLine(for: 4) == 0)
        #expect(view.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 5))
        #expect(view.accessibilityRange(for: 0) == NSRange(location: 0, length: 2))
        #expect(runtime.accessibilityEnableCount == 0)
        #expect(runtime.accessibilityStreamSubscriptionCount == 1)

        view.setAccessibilityValue("typed")
        #expect(runtime.mutations.last == .input(.text(TerminalExternalTextInput(
            text: "typed",
            kind: .committed
        ))))
    }

    @Test func AXObservationReleasesStreamDemandWhenUnmountedAndDeinitialized() async {
        let snapshot = makeAccessibilitySnapshot(contentSequence: 13, text: "owned")
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = makeRuntimeSnapshot(accessibility: snapshot)
        runtime.keepAccessibilityStreamsOpen = true
        var view: TerminalFrontendInteractionView? = TerminalFrontendInteractionView(
            runtime: runtime
        )
        var window: NSWindow? = view.map(mount)

        _ = view?.accessibilityValue()
        #expect(runtime.accessibilityStreamSubscriptionCount == 1)
        #expect(runtime.accessibilityStreamTerminationCount == 0)

        window?.contentView = nil
        for _ in 0 ..< 4 where runtime.accessibilityStreamTerminationCount == 0 {
            await Task.yield()
        }
        #expect(runtime.accessibilityStreamTerminationCount == 1)

        if let view {
            window?.contentView = view
            _ = view.accessibilityValue()
        }
        #expect(runtime.accessibilityStreamSubscriptionCount == 2)
        window = nil
        view = nil
        for _ in 0 ..< 4 where runtime.accessibilityStreamTerminationCount < 2 {
            await Task.yield()
        }
        #expect(runtime.accessibilityStreamTerminationCount == 2)
    }

    @Test func AXBoundsRoundTripThroughVisibleGridCoordinates() throws {
        let snapshot = makeAccessibilitySnapshot(
            contentSequence: 9,
            text: "ab",
            columns: 2,
            rows: 1,
            lines: [TerminalAccessibilityLine(
                row: 40,
                utf16Range: TerminalAccessibilityRange(location: 0, length: 2),
                cells: [
                    TerminalAccessibilityCell(
                        column: 0,
                        columnSpan: 1,
                        utf16Range: TerminalAccessibilityRange(location: 0, length: 1)
                    ),
                    TerminalAccessibilityCell(
                        column: 1,
                        columnSpan: 1,
                        utf16Range: TerminalAccessibilityRange(location: 1, length: 1)
                    ),
                ]
            )]
        )
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = makeRuntimeSnapshot(
            columns: 2,
            rows: 1,
            paddingLeftPixels: 4,
            paddingTopPixels: 6,
            accessibility: snapshot
        )
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 40, height: 40),
            runtime: runtime
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: 100, y: 300))
        window.contentView = view

        let frame = view.accessibilityFrame(for: NSRange(location: 0, length: 1))
        #expect(frame.width == 10)
        #expect(frame.height == 20)
        #expect(frame.minX == 104)
        #expect(frame.minY == 314)
        #expect(view.accessibilityRange(for: NSPoint(x: frame.midX, y: frame.midY))
            == NSRange(location: 0, length: 1))

        runtime.snapshot = makeRuntimeSnapshot(
            columns: 2,
            rows: 1,
            paddingLeftPixels: 4,
            paddingTopPixels: 6,
            cursor: TerminalExternalCursorState(column: 0, row: 40, visible: true),
            viewportState: TerminalExternalViewportState(
                totalRows: 41,
                offset: 40,
                visibleRows: 1
            ),
            accessibility: snapshot
        )
        let caretFrame = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        #expect(caretFrame.minX == 104)
        #expect(caretFrame.minY == 314)
    }

    @Test func AXLinkChildrenRejectStaleRevisionsAndOpenOnlyValidatedTargets() async throws {
        let first = makeAccessibilitySnapshot(
            contentSequence: 10,
            text: "first",
            links: [TerminalAccessibilityLink(
                id: "first",
                target: "https://example.com/first",
                utf16Range: TerminalAccessibilityRange(location: 0, length: 5),
                row: 40,
                startColumn: 0,
                endColumn: 4
            )]
        )
        let second = makeAccessibilitySnapshot(
            contentSequence: 11,
            text: "second",
            links: [TerminalAccessibilityLink(
                id: "second",
                target: "https://example.com/second",
                utf16Range: TerminalAccessibilityRange(location: 0, length: 6),
                row: 40,
                startColumn: 0,
                endColumn: 5
            )]
        )
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = makeRuntimeSnapshot(accessibility: first)
        let opened = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let view = TerminalFrontendInteractionView(
            frame: .zero,
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero),
            accessibilityLinkOpener: { target in
                opened.continuation.yield(target)
                return true
            },
            keyEventInterpreter: nil
        )
        let window = mount(view)
        #expect(window.contentView === view)
        let staleChild = try #require(
            view.accessibilityChildren()?.first as? NSAccessibilityElement
        )
        #expect(staleChild.accessibilityRole() == .link)
        #expect(staleChild.accessibilityLabel() == "first")
        #expect(staleChild.accessibilityFrame().width == 50)

        runtime.snapshot = makeRuntimeSnapshot(accessibility: second)
        #expect(view.accessibilityValue() as? String == "second")
        #expect(!staleChild.accessibilityPerformPress())
        #expect(runtime.accessibilityLinkActivations.isEmpty)

        let currentChild = try #require(
            view.accessibilityChildren()?.first as? NSAccessibilityElement
        )
        #expect(currentChild.accessibilityIdentifier() == "second")
        #expect(currentChild.accessibilityPerformPress())
        var iterator = opened.stream.makeAsyncIterator()
        #expect(await iterator.next() == "https://example.com/second")
        #expect(runtime.accessibilityLinkActivations.count == 1)
    }

    @Test func retainedAXLinkRejectsAfterBridgeOwnerTeardown() throws {
        let snapshot = makeAccessibilitySnapshot(
            contentSequence: 12,
            text: "link",
            links: [TerminalAccessibilityLink(
                id: "retained",
                target: "https://example.com/retained",
                utf16Range: TerminalAccessibilityRange(location: 0, length: 4),
                row: 40,
                startColumn: 0,
                endColumn: 3
            )]
        )
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = makeRuntimeSnapshot(accessibility: snapshot)
        weak var weakBridge: TerminalFrontendAccessibilityBridge?
        var view: TerminalFrontendInteractionView? = TerminalFrontendInteractionView(
            runtime: runtime
        )
        var window: NSWindow?
        var retainedChild: NSAccessibilityElement?
        if let mountedView = view {
            weakBridge = mountedView.accessibilityBridge
            window = mount(mountedView)
            retainedChild = mountedView.accessibilityChildren()?.first as? NSAccessibilityElement
        }
        window?.contentView = nil
        view = nil
        window = nil

        #expect(weakBridge == nil)
        let retainedChildElement = try #require(retainedChild)
        #expect(retainedChildElement.accessibilityParent() == nil)
        #expect(!retainedChildElement.accessibilityPerformPress())
        #expect(runtime.accessibilityLinkActivations.isEmpty)
    }

    @Test func TrackingAndEditActionsStayInTheLightweightResponderHost() async throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = makeRuntimeSnapshot(
            selection: TerminalExternalSelection(
                text: "copy me",
                start: TerminalExternalCellPoint(column: 0, row: 0),
                end: TerminalExternalCellPoint(column: 7, row: 0),
                topLeft: TerminalExternalCellPoint(column: 0, row: 0),
                bottomRight: TerminalExternalCellPoint(column: 7, row: 0),
                rectangle: false
            )
        )
        runtime.stubbedSelection = runtime.snapshot.selection
        let clipboard = RecordingTerminalClipboard()
        clipboard.readValue = "paste me"
        let copied = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        clipboard.didWrite = { copied.continuation.yield($0) }
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero),
            clipboardWriter: clipboard,
            clipboardReader: clipboard,
            keyEventInterpreter: nil
        )

        view.updateTrackingAreas()
        let options = try #require(
            view.trackingAreas.first(where: { $0.owner === view })
        ).options
        #expect(options.contains(.inVisibleRect))
        #expect(options.contains(.activeInKeyWindow))
        #expect(options.contains(.mouseMoved))
        #expect(options.contains(.mouseEnteredAndExited))

        let copyItem = NSMenuItem(
            title: "",
            action: #selector(TerminalFrontendInteractionView.copy(_:)),
            keyEquivalent: ""
        )
        let pasteItem = NSMenuItem(
            title: "",
            action: #selector(TerminalFrontendInteractionView.paste(_:)),
            keyEquivalent: ""
        )
        let selectAllItem = NSMenuItem(
            title: "",
            action: #selector(TerminalFrontendInteractionView.selectAll(_:)),
            keyEquivalent: ""
        )
        #expect(view.validateUserInterfaceItem(copyItem))
        #expect(view.validateUserInterfaceItem(pasteItem))
        #expect(view.validateUserInterfaceItem(selectAllItem))

        view.copy(nil)
        var copiedIterator = copied.stream.makeAsyncIterator()
        #expect(await copiedIterator.next() == "copy me")
        view.paste(nil)
        view.selectAll(nil)
        #expect(Array(runtime.mutations.suffix(2)) == [
            .input(.text(TerminalExternalTextInput(text: "paste me", kind: .paste))),
            .selection(.selectAll),
        ])
    }

    private func makeRuntimeSnapshot(
        columns: Int = 10,
        rows: Int = 5,
        paddingLeftPixels: Int? = nil,
        paddingTopPixels: Int? = nil,
        cursor: TerminalExternalCursorState? = nil,
        selection: TerminalExternalSelection? = nil,
        viewportState: TerminalExternalViewportState? = nil,
        accessibility: TerminalAccessibilitySnapshot? = nil
    ) -> TerminalExternalRuntimeSnapshot {
        TerminalExternalRuntimeSnapshot(
            lifecycle: .live,
            visibleText: accessibility?.text,
            cellMetrics: TerminalExternalCellMetrics(
                columns: columns,
                rows: rows,
                cellWidthPixels: 10,
                cellHeightPixels: 20,
                surfaceWidthPixels: columns * 10,
                surfaceHeightPixels: rows * 20,
                backingScale: 1,
                paddingLeftPixels: paddingLeftPixels,
                paddingTopPixels: paddingTopPixels
            ),
            cursor: cursor,
            selection: selection,
            viewportState: viewportState,
            accessibility: accessibility
        )
    }

    private func mount(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    private func makeAccessibilitySnapshot(
        contentSequence: UInt64,
        text: String,
        columns: Int = 10,
        rows: Int = 5,
        lines: [TerminalAccessibilityLine] = [],
        cursor: TerminalAccessibilityCursor? = nil,
        selections: [TerminalAccessibilitySelection] = [],
        links: [TerminalAccessibilityLink] = []
    ) -> TerminalAccessibilitySnapshot {
        TerminalAccessibilitySnapshot(
            schemaVersion: 1,
            surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            presentationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            presentationGeneration: 3,
            contentSequence: contentSequence,
            terminalRevision: contentSequence,
            contentRevision: contentSequence,
            viewportRevision: contentSequence,
            viewportOffset: 40,
            columns: columns,
            rows: rows,
            text: text,
            lines: lines,
            cursor: cursor,
            selections: selections,
            links: links,
            focused: true
        )
    }
}

@Suite struct TerminalFrontendAccessibilityLinkActionGateTests {
    @Test func invalidationRejectsActionsFromNonisolatedCallers() async {
        let actions = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let gate = TerminalFrontendAccessibilityLinkActionGate {
            actions.continuation.yield()
        }

        #expect(await Task.detached { gate.perform() }.value)
        var iterator = actions.stream.makeAsyncIterator()
        _ = await iterator.next()

        gate.invalidate()
        let acceptedAfterInvalidation = await Task.detached { gate.perform() }.value
        #expect(!acceptedAfterInvalidation)
    }

    @Test func copiedActionCompletesOutsideTheInvalidationLock() async {
        let actionStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let allowActionToFinish = DispatchSemaphore(value: 0)
        let gate = TerminalFrontendAccessibilityLinkActionGate {
            actionStarted.continuation.yield()
            allowActionToFinish.wait()
        }
        let firstPerform = Task.detached { gate.perform() }
        var iterator = actionStarted.stream.makeAsyncIterator()
        _ = await iterator.next()

        gate.invalidate()
        let acceptedAfterInvalidation = await Task.detached { gate.perform() }.value
        #expect(!acceptedAfterInvalidation)
        allowActionToFinish.signal()
        #expect(await firstPerform.value)
    }
}

@MainActor
private final class RecordingTerminalClipboard: TerminalFrontendClipboardWriting,
    TerminalFrontendClipboardReading
{
    var readValue: String?
    var didWrite: ((String) -> Void)?

    func readTerminalText() -> String? { readValue }

    func writeTerminalText(_ text: String) -> Bool {
        didWrite?(text)
        return true
    }
}
