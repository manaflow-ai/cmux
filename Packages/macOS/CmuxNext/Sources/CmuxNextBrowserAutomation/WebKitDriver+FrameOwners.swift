import CmuxNextBrowser
import Foundation
import WebKit

/// Which frame an `<iframe>` holds, and where it sits in its parent: the
/// driver half of entering a frame (`frame.contentFrame`, `frame.ownerBox`).
///
/// WebKit gives no element-to-frame link, so both sides meet on one order:
/// `window.frames[i]` and the `_frames:` tree list a frame's children in the
/// same order (WebKit's frame tree child order, which is creation order, not
/// document order). The parent finds the iframe's index by window identity
/// (`window.frames[i] === iframe.contentWindow`), and the tree's i-th child
/// of that parent is the frame. When the counts differ (an iframe in a
/// shadow tree is in the tree but not in `window.frames`), there is no
/// answer instead of a guess.
extension WebKitDriver {
    func frameContentFrame(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let element = try params.string("element")
        let parent = try await frameInfo(params, tab: tab, session: session)
        let position = try await runInAgent("""
        const [el] = __handlesThenArgs(__handles, __args);
        const win = el.contentWindow;
        if (!win) return null;
        for (let i = 0; i < window.frames.length; i++) if (window.frames[i] === win) return [i, window.frames.length];
        return null;
        """, handles: [element], frame: parent, tab: tab)
        guard case .array(let pair) = position, pair.count == 2,
              case .number(let index) = pair[0], case .number(let count) = pair[1] else { return .null }
        let records = await session.frames.refresh(tab.webView)
        let parentID = parent.flatMap(FrameTree.frameID) ?? records.first?.frameID
        let children = records.filter { $0.parentFrameID == parentID }
        guard children.count == Int(count), Int(index) < children.count else { return .null }
        return .object(["frameId": .string(children[Int(index)].frameID)])
    }

    /// The owner `<iframe>`'s content box in its parent frame's viewport.
    func frameOwnerBox(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let frameID = try params.string("frameId")
        let records = await session.frames.refresh(tab.webView)
        guard let record = records.first(where: { $0.frameID == frameID }), let parentID = record.parentFrameID,
              let parent = records.first(where: { $0.frameID == parentID }) else {
            throw DriverError(.notFound, "Frame \(frameID) has no owner element")
        }
        let siblings = records.filter { $0.parentFrameID == parentID }
        guard let index = siblings.firstIndex(where: { $0.frameID == frameID }) else {
            throw DriverError(.notFound, "Frame \(frameID) has no owner element")
        }
        let box = try await run("""
        if (window.frames.length !== count) return null;
        const win = window.frames[index];
        const owners = [];
        const walk = (root) => {
          for (const el of root.querySelectorAll("iframe, frame")) owners.push(el);
          for (const el of root.querySelectorAll("*")) if (el.shadowRoot) walk(el.shadowRoot);
        };
        walk(document);
        const owner = owners.find((el) => el.contentWindow === win);
        if (!owner) return null;
        const r = owner.getBoundingClientRect();
        const cs = getComputedStyle(owner);
        const px = (v) => parseFloat(v) || 0;
        return {
          x: r.left + owner.clientLeft + px(cs.paddingLeft),
          y: r.top + owner.clientTop + px(cs.paddingTop),
          width: owner.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight),
          height: owner.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom),
        };
        """, ["index": index, "count": siblings.count], parent.isMain ? nil : parent.info, AgentWorld.hostWorld, tab)
        guard box != .null else { throw DriverError(.notFound, "Frame \(frameID) has no owner element") }
        return box
    }
}
