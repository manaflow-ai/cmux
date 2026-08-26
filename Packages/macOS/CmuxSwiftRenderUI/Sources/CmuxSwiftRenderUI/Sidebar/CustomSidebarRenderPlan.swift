import CmuxSwiftRender
import Foundation

/// Immutable input prepared off the main actor for a mounted sidebar render.
public struct CustomSidebarRenderPlan: Sendable {
    /// The source file that produced this plan.
    public let fileURL: URL
    /// The source format used to create the plan.
    public let kind: CustomSidebarFileKind
    /// The decoded state passed to ``CustomSidebarContentView``.
    public let state: CustomSidebarModel.State
    /// The interpreted Swift tree, when the source is Swift.
    public let swiftRender: RenderNode?
    /// Whether Swift interpretation completed, including a no-view result.
    public let hasRenderedSwift: Bool

    /// Creates a prepared render plan.
    ///
    /// - Parameters:
    ///   - fileURL: The source file represented by the plan.
    ///   - kind: The source format.
    ///   - state: The value state mounted by the shared content view.
    ///   - swiftRender: The interpreted tree for Swift sources, if available.
    ///   - hasRenderedSwift: Whether Swift interpretation has completed.
    public init(
        fileURL: URL,
        kind: CustomSidebarFileKind,
        state: CustomSidebarModel.State,
        swiftRender: RenderNode?,
        hasRenderedSwift: Bool
    ) {
        self.fileURL = fileURL
        self.kind = kind
        self.state = state
        self.swiftRender = swiftRender
        self.hasRenderedSwift = hasRenderedSwift
    }
}
