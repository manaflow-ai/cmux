internal import AppKit
public import CmuxTerminalDomain
public import Foundation

/// Lightweight frontend boundary for one persistent terminal presentation.
///
/// The panel owns only presentation identity, a Ghostty-free surface view, and
/// a forwarding reference to the backend-owned canonical runtime. It creates
/// no PTY, parser, Ghostty surface, font atlas, or terminal renderer.
@MainActor
public final class TerminalFrontendPanel: TerminalExternalRuntime {
    /// The terminal identity that remains stable across Swift host restarts.
    public let surfaceID: UUID

    /// The latest backend-authoritative workspace placement.
    public private(set) var workspaceID: UUID

    /// The Ghostty-free view where the authenticated compositor is mounted.
    public let surfaceView: TerminalFrontendSurfaceView

    private let runtime: any TerminalExternalRuntime

    /// Creates a lightweight frontend around an externally owned runtime.
    ///
    /// - Parameters:
    ///   - surfaceID: The stable canonical terminal identity.
    ///   - workspaceID: The initial canonical workspace placement.
    ///   - runtime: The backend adapter that owns canonical terminal state.
    public convenience init(
        surfaceID: UUID,
        workspaceID: UUID,
        runtime: any TerminalExternalRuntime
    ) {
        self.init(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero)
        )
    }

    /// Creates a lightweight frontend with an injected visual surface.
    ///
    /// - Parameters:
    ///   - surfaceID: The stable canonical terminal identity.
    ///   - workspaceID: The initial canonical workspace placement.
    ///   - runtime: The backend adapter that owns canonical terminal state.
    ///   - surfaceView: The visual host used for compositor mounting.
    public init(
        surfaceID: UUID,
        workspaceID: UUID,
        runtime: any TerminalExternalRuntime,
        surfaceView: TerminalFrontendSurfaceView
    ) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.runtime = runtime
        self.surfaceView = surfaceView
    }

    /// The last coherent state snapshot supplied by the canonical runtime.
    public var snapshot: TerminalExternalRuntimeSnapshot {
        runtime.snapshot
    }

    /// Attaches the compatibility presentation to the canonical runtime.
    public func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        precondition(
            presentation.surfaceID == surfaceID,
            "A frontend panel cannot present a different terminal identity"
        )
        workspaceID = presentation.workspaceID
        return runtime.attachPresentation(presentation)
    }

    /// Installs a committed placement and forwards it to the canonical runtime.
    public func adoptCanonicalPlacement(workspaceID: UUID) {
        self.workspaceID = workspaceID
        runtime.adoptCanonicalPlacement(workspaceID: workspaceID)
    }

    /// Forwards one bounded ordered mutation to the canonical runtime.
    @discardableResult
    public func enqueue(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        runtime.enqueue(mutation)
    }

    /// Reads bounded terminal text from the canonical runtime.
    public func readScreenText(
        _ request: TerminalExternalScreenTextRequest
    ) async -> String? {
        await runtime.readScreenText(request)
    }

    /// Reads the current canonical selection.
    public func readSelection() async -> TerminalExternalSelection? {
        await runtime.readSelection()
    }

    /// Enables demand-driven accessibility state in the canonical runtime.
    public func enableAccessibility() {
        runtime.enableAccessibility()
    }

    /// Streams changed accessibility snapshots from the canonical runtime.
    public func accessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot> {
        runtime.accessibilitySnapshots()
    }

    /// Revalidates and activates an accessibility link through the backend.
    public func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        await runtime.activateAccessibilityLink(link, snapshot: snapshot)
    }

    /// Revalidates and activates a pointer hyperlink through the backend.
    public func activateHyperlink(
        at event: TerminalExternalMouseEvent
    ) async -> TerminalExternalHyperlinkHit? {
        await runtime.activateHyperlink(at: event)
    }
}
