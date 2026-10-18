public import CoreGraphics
import Foundation

/// What an `input.mouse` press must reach: the element the runtime checked
/// at the point, in its frame, and each parent frame's `<iframe>` that
/// shows the frame below it, up to the tab (`expect` in the protocol).
///
/// The runtime checks these before it asks for the press, but the press
/// is another driver call, and the page runs in between: it can put
/// another element, or another frame, at the point. The driver checks
/// them again right before it sends the press, in each frame's agent
/// world in the web content process, and refuses the press (`stale`,
/// `no press was sent: …`) when any changed. WebKit runs no script
/// between its hit test of a native event and the event's dispatch, so
/// the check cannot ride on the event itself: what stays open is the
/// time from the checks to the press reaching the web content process
/// (the checks' replies and the press, one message each way).
public struct BrowserReplPressTarget: Equatable, Sendable {
    /// One frame's part of the press.
    public struct Level: Equatable, Sendable {
        /// The frame the check runs in; `nil` is the main frame.
        public let frameID: String?
        /// The agent's handle of the target (first level) or of the
        /// `<iframe>` that shows the frame of the level before.
        public let handle: String
        /// Where the press lands in this frame's viewport.
        public let point: CGPoint
        /// For an `<iframe>`: the press's point in the frame it shows.
        public let childPoint: CGPoint?
    }

    /// The target's level first, then each parent frame's, up to the main frame.
    public let levels: [Level]

    /// WebKit holds at most 1,000 frames in a page, so no chain is longer.
    static let maxLevels = 1_000

    /// Reads `expect` of an `input.mouse` press:
    /// `{ frameId?, handle, x, y, owners?: [{ frameId?, handle, x, y }] }`,
    /// where each owner's point is where the level before lands in that
    /// frame, and the last point is the press's own.
    /// - Returns: `nil` when the press names no target (`page.mouse.down()`).
    /// - Throws: `invalid` when `expect` is malformed or does not end at `press`.
    public init?(expect: Any?, press: CGPoint) throws {
        guard let expect, !(expect is NSNull) else { return nil }
        guard let object = expect as? [String: Any] else {
            throw Self.invalid("expect must be an object")
        }
        var levels = [try Self.level(object, childPoint: nil)]
        let owners: [Any]
        switch object["owners"] {
        case nil, is NSNull: owners = []
        case let list as [Any]: owners = list
        default: throw Self.invalid("expect.owners must be an array")
        }
        guard owners.count < Self.maxLevels else {
            throw Self.invalid("expect.owners names more frames than a tab can hold (\(Self.maxLevels))")
        }
        for owner in owners {
            guard let owner = owner as? [String: Any] else { throw Self.invalid("each of expect.owners must be an object") }
            levels.append(try Self.level(owner, childPoint: levels[levels.count - 1].point))
        }
        guard levels[levels.count - 1].point == press else {
            throw Self.invalid("expect does not end at the press point")
        }
        self.levels = levels
    }

    private static func level(_ object: [String: Any], childPoint: CGPoint?) throws -> Level {
        let frameID: String?
        switch object["frameId"] {
        case nil, is NSNull: frameID = nil
        case let id as String: frameID = id.isEmpty ? nil : id
        default: throw invalid("expect.frameId must be a string")
        }
        guard let handle = object["handle"] as? String, !handle.isEmpty, handle.utf8.count <= 256 else {
            throw invalid("expect.handle must be an element handle")
        }
        guard let x = number(object["x"]), let y = number(object["y"]) else {
            throw invalid("expect.x and expect.y must be finite numbers")
        }
        return Level(frameID: frameID, handle: handle, point: CGPoint(x: x, y: y), childPoint: childPoint)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func invalid(_ message: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "invalid", message: "input.mouse: \(message)")
    }

    private static func refused(_ why: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "stale", message: "no press was sent: \(why) when the press was about to be sent (the page changed under the pointer)")
    }

    /// Each level's frame in `tree`, checked to be the parent of the frame
    /// of the level before; the last one is the main frame.
    /// - Throws: `stale` when a frame is gone or the frames do not nest so.
    public func frames(in tree: [BrowserReplFrame]) throws -> [BrowserReplFrame] {
        guard let main = tree.first(where: { $0.parentFrameID == nil }) else {
            throw Self.refused("the tab has no main frame")
        }
        var frames: [BrowserReplFrame] = []
        for level in levels {
            if let id = level.frameID {
                guard let frame = tree.first(where: { $0.frameID == id }) else {
                    throw Self.refused("frame \(id) was detached")
                }
                frames.append(frame)
            } else {
                frames.append(main)
            }
        }
        for (inner, outer) in zip(frames, frames.dropFirst()) where inner.parentFrameID != outer.frameID {
            throw Self.refused("frame \(inner.frameID) is not in frame \(outer.frameID)")
        }
        if let top = frames.last, top.parentFrameID != nil {
            throw Self.refused("frame \(top.frameID) is in a frame the press does not name")
        }
        return frames
    }

    /// The check, a `callAsyncJavaScript` body run in a frame's agent world
    /// with ``arguments(of:)``: `true`, or why the press would not reach
    /// the level's element (the page agent's `pressCheck`).
    public static let checkBody = """
        const agent = globalThis[\(BrowserReplRuntimeBundle.agentGlobalKeyExpression)];
        if (!agent || typeof agent.pressCheck !== "function") return "the frame shows another document";
        const why = agent.pressCheck(__handle, __at, __from);
        return why === null ? true : String(why);
        """

    /// The arguments of ``checkBody`` for `level`.
    public static func arguments(of level: Level) -> [String: Any] {
        [
            "__handle": level.handle,
            "__at": ["x": level.point.x, "y": level.point.y],
            "__from": level.childPoint.map { ["x": $0.x, "y": $0.y] as Any } ?? NSNull(),
        ]
    }

    private enum Outcome: Sendable {
        case passed
        case failed(String)
        case error(BrowserReplDriverError)
    }

    /// Checks every level at once, right before the press: all checks
    /// start in one main-thread turn, so the web content process runs them
    /// back to back, and this returns as soon as the last one answers, for
    /// the caller to send the press without another suspension.
    /// - Parameters:
    ///   - tree: the tab's frame tree, read before (a read here would
    ///     widen the window between the checks and the press).
    ///   - run: runs ``checkBody`` with its arguments in a frame's agent world.
    /// - Throws: `stale` (`no press was sent: …`) when the press would not
    ///   reach the target, or the error `run` threw with a driver code
    ///   (a frame the domain policy blocks).
    @MainActor
    public func verify(
        frames tree: [BrowserReplFrame],
        run: @escaping @MainActor (_ body: String, _ arguments: [String: Any], _ frame: BrowserReplFrame) async throws -> Any?
    ) async throws {
        let frames = try frames(in: tree)
        let checks = zip(levels, frames).map { level, frame in
            Task { @MainActor () -> Outcome in
                do {
                    let value = try await run(Self.checkBody, Self.arguments(of: level), frame)
                    if let why = value as? String { return .failed(why) }
                    return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
                        ? .passed
                        : .failed("the frame did not answer the check")
                } catch let error as BrowserReplDriverError {
                    return .error(error)
                } catch {
                    return .failed("the check failed (\(error.localizedDescription))")
                }
            }
        }
        var first: (any Error)?
        for check in checks {
            switch await check.value {
            case .passed: continue
            case .failed(let why): first = first ?? Self.refused(why)
            case .error(let error) where error.code == "stale": first = first ?? Self.refused(error.message)
            case .error(let error): first = first ?? error
            }
        }
        if let first { throw first }
    }
}
