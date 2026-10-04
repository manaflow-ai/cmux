public import WebKit

/// Ties a parent frame's `window.frames` positions to its child frames'
/// ids in WebKit's frame tree.
///
/// Models the driver as it is: a frame's position is its index among the
/// parent's children in the tree, read again after the parent's script.
@MainActor
public struct BrowserReplFrameBinding {
    private let world: WKContentWorld

    public init(world: WKContentWorld, probeTimeout: Duration = .seconds(5)) {
        self.world = world
    }

    public func bind<T>(
        parentID: String?,
        in webView: WKWebView,
        readTree: @MainActor () async -> [BrowserReplFrame],
        body: @MainActor ([String: Int]) async throws -> (value: T, length: Int)
    ) async throws -> (value: T, children: [Int: String])? {
        let before = await readTree()
        let parent = parentID ?? before.first?.frameID
        var positions: [String: Int] = [:]
        for child in before where child.parentFrameID == parent { positions[child.frameID] = child.indexInParent }
        let (value, _) = try await body(positions)
        let after = await readTree()
        var children: [Int: String] = [:]
        for child in after where child.parentFrameID == parent { children[child.indexInParent] = child.frameID }
        return (value, children)
    }
}
