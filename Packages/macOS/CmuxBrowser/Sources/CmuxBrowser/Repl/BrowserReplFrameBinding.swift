public import WebKit

/// Ties a parent frame's `window.frames` positions to its child frames'
/// ids in WebKit's frame tree, or fails closed.
///
/// Script in the parent sees an `<iframe>`'s window and its position in
/// `window.frames`; WebKit's tree names child frames by id. The two lists
/// differ: `window.frames` leaves out frames in shadow trees, and the page
/// adds and removes frames between any two reads. So each child frame
/// says where it is itself: a probe in the child, in a content world page
/// and agent code cannot reach, finds its own window in `parent.frames`
/// (indexed access and `length` work across origins). The binding holds
/// only when the parent's children in the tree are the same frames, in
/// the same order, before the probes and after the parent's script, and
/// every probe and the parent's script saw a `window.frames` as long as
/// the number of children that found themselves in it, all at distinct
/// positions. A frame that is removed never comes back (frame ids are not
/// reused) and WebKit orders a parent's children by when they were
/// created, so the same tree on both sides means no frame was removed
/// between, and the matching lengths mean no frame was added at any of the
/// reads: every read saw the same `window.frames`. Otherwise it reads
/// again, and after three tries it binds nothing (`nil`).
@MainActor
public struct BrowserReplFrameBinding {
    private let world: WKContentWorld
    private let prober: BrowserReplScriptProbe

    /// - Parameters:
    ///   - world: a content world agent and page code cannot reach.
    ///   - probeTimeout: the bound on each child's probe.
    public init(world: WKContentWorld, probeTimeout: Duration = .seconds(2)) {
        self.world = world
        prober = BrowserReplScriptProbe(timeout: probeTimeout)
    }

    /// Runs `body`, script in the parent that reports a value and the
    /// parent's `window.frames.length` at that moment, between two reads
    /// of the tree, and returns the value with the parent's child frames by
    /// `window.frames` position. `body` gets each child frame's position
    /// (frames in shadow trees have none) as it held when `body` ran.
    ///
    /// - Parameters:
    ///   - parentID: the parent's id in the tree; `nil` names the main frame.
    ///   - readTree: reads the tree as it is now.
    /// - Returns: `nil` when the positions could not be tied to frames.
    public func bind<T>(
        parentID: String?,
        in webView: WKWebView,
        readTree: @MainActor () async -> [BrowserReplFrame],
        body: @MainActor ([String: Int]) async throws -> (value: T, length: Int)
    ) async throws -> (value: T, children: [Int: String])? {
        for _ in 0..<3 {
            let before = await readTree()
            guard let parent = parentID ?? before.first?.frameID else { return nil }
            let children = before.filter { $0.parentFrameID == parent }
            let answers = await probe(children, in: webView)
            guard let positions = Self.positions(answers) else {
                // A child that did not answer is not asked again: it would
                // hold every try for the probe's bound.
                if answers.contains(where: { $0 == nil }) { return nil }
                continue
            }
            let (value, length) = try await body(positions.byFrame)
            let after = await readTree().filter { $0.parentFrameID == parent }
            guard length == positions.length,
                  after.map(\.frameID) == children.map(\.frameID) else { continue }
            var byPosition: [Int: String] = [:]
            for (id, position) in positions.byFrame { byPosition[position] = id }
            return (value, byPosition)
        }
        return nil
    }

    private struct Answer: Equatable {
        let id: String
        let position: Int
        let length: Int
    }

    /// Each child's own answer, `nil` where it did not answer in time.
    /// The children answer concurrently.
    private func probe(_ children: [BrowserReplFrame], in webView: WKWebView) async -> [Answer?] {
        let tasks = children.map { child in
            Task { @MainActor () -> Answer? in
                guard let info = child.info,
                      let value = try? await prober.call(
                          Self.positionSource, arguments: [:], in: webView, frame: info,
                          contentWorld: world, what: "frame \(child.frameID) did not report its position"
                      ) as? [NSNumber], value.count == 2 else { return nil }
                return Answer(id: child.frameID, position: value[0].intValue, length: value[1].intValue)
            }
        }
        var answers: [Answer?] = []
        for task in tasks { answers.append(await task.value) }
        return answers
    }

    /// The children's positions by frame id, with the length of the list,
    /// when every answer saw the same length and the children that found
    /// themselves fill it exactly. A child that did not answer has no
    /// position; that holds only while the others fill the list, which
    /// means it is in a shadow tree (were it in the list, one place would
    /// stay empty).
    private static func positions(_ answers: [Answer?]) -> (byFrame: [String: Int], length: Int)? {
        let known = answers.compactMap { $0 }
        let length = known.first?.length ?? 0
        guard known.allSatisfy({ $0.length == length }) else { return nil }
        let placed = known.filter { $0.position >= 0 }
        guard placed.count == length, Set(placed.map(\.position)).count == length,
              placed.allSatisfy({ $0.position < length }) else { return nil }
        if known.isEmpty, !answers.isEmpty { return nil }
        return (Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.position) }), length)
    }

    /// Runs in the child, in the binding's world: its own window's position
    /// in `parent.frames` (-1 when it is in a shadow tree) and that list's
    /// length. Only the engine's window objects are read.
    private static let positionSource = """
    const p = window.parent;
    if (p === window) return [-1, 0];
    const length = p.length;
    for (let i = 0; i < length; i++) if (p[i] === window) return [i, length];
    return [-1, length];
    """
}
