import CmuxTerminalFrontend
import Foundation

@MainActor
final class FakeTerminalExternalRuntime: TerminalExternalRuntime {
    var snapshot = TerminalExternalRuntimeSnapshot(
        lifecycle: .live,
        visibleText: "backend-owned"
    )
    let lease = FakeTerminalExternalPresentationLease()
    private(set) var presentations: [TerminalExternalPresentation] = []
    private(set) var adoptedWorkspaceIDs: [UUID] = []
    private(set) var mutations: [TerminalExternalRuntimeMutation] = []
    private(set) var accessibilityEnableCount = 0
    private(set) var accessibilityStreamSubscriptionCount = 0
    private(set) var selectionReadCount = 0
    private(set) var accessibilityLinkActivations: [(
        link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    )] = []
    var stubbedIngressResults: [TerminalExternalIngressResult] = []
    var stubbedSelection: TerminalExternalSelection? = TerminalExternalSelection(
        text: "selected",
        start: TerminalExternalCellPoint(column: 1, row: 2),
        end: TerminalExternalCellPoint(column: 3, row: 2),
        topLeft: TerminalExternalCellPoint(column: 1, row: 2),
        bottomRight: TerminalExternalCellPoint(column: 3, row: 2),
        rectangle: false
    )
    var stubbedAccessibilitySnapshots: [TerminalAccessibilitySnapshot] = []
    var stubbedAccessibilityStream: AsyncStream<TerminalAccessibilitySnapshot>?
    var stubbedAccessibilityLinkTarget: String?
    private var stubbedIngressResultIndex = 0

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        presentations.append(presentation)
        return lease
    }

    func adoptCanonicalPlacement(workspaceID: UUID) {
        adoptedWorkspaceIDs.append(workspaceID)
    }

    func enqueue(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        mutations.append(mutation)
        if stubbedIngressResultIndex < stubbedIngressResults.count {
            defer { stubbedIngressResultIndex += 1 }
            return stubbedIngressResults[stubbedIngressResultIndex]
        }
        return .accepted(sequence: UInt64(mutations.count))
    }

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String? {
        switch request {
        case .visible:
            "visible text"
        case .vtTail:
            "tail text"
        }
    }

    func readSelection() async -> TerminalExternalSelection? {
        selectionReadCount += 1
        return stubbedSelection
    }

    func enableAccessibility() {
        accessibilityEnableCount += 1
    }

    func accessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot> {
        accessibilityStreamSubscriptionCount += 1
        if let stubbedAccessibilityStream {
            return stubbedAccessibilityStream
        }
        let snapshots = stubbedAccessibilitySnapshots
        return AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        accessibilityLinkActivations.append((link, snapshot))
        return stubbedAccessibilityLinkTarget ?? link.target
    }

    func activateHyperlink(
        at event: TerminalExternalMouseEvent
    ) async -> TerminalExternalHyperlinkHit? {
        TerminalExternalHyperlinkHit(
            target: "https://example.com",
            contentSequence: 4,
            presentationGeneration: 5,
            column: UInt16(clamping: Int(event.xPixels)),
            row: UInt64(clamping: Int(event.yPixels))
        )
    }
}
