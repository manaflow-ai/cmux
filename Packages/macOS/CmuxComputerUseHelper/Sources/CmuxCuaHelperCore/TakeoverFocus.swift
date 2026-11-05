// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation

/// The window server lookups behind the collision rule: which app and window
/// the person is using, and which app owns a window an agent call names.
enum TakeoverFocusProbe {
    /// The person's apps and window: the frontmost app (it gets their keys),
    /// and the topmost window under their last pointer position with its app
    /// (it gets their clicks and scrolls). Windows of `ownPID` (the agent's
    /// cursor overlay) are skipped. Nil when neither could be read, which the
    /// gate treats as a collision.
    static func personFocus(ownPID: pid_t) -> TakeoverGate.FocusProvider {
        { pointer in
            var focus = PersonFocus()
            if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                focus.pids.insert(front)
            }
            if let pointer, let hit = window(at: CGPoint(x: pointer.x, y: pointer.y), skipping: ownPID) {
                focus.pids.insert(hit.pid)
                focus.windowIDs.insert(hit.id)
            }
            return focus.pids.isEmpty ? nil : focus
        }
    }

    /// The pid that owns window `id`, or nil when it is gone.
    static func owner(ofWindow id: UInt32) -> Int32? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        return pid
    }

    /// On-screen windows come front to back; the first visible one that
    /// contains `point` (global, top-left origin, like the tap's locations) is hit.
    static func window(at point: CGPoint, skipping ownPID: pid_t) -> (id: UInt32, pid: Int32)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windows {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.contains(point) else { continue }
            return (id, pid)
        }
        return nil
    }
}
