// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import ApplicationServices
import Foundation

/// The last snapshot of one app: what its element indexes refer to.
struct AppSnapshot: @unchecked Sendable {
    let app: RunningApp
    let window: WindowInfo?
    let windowElement: AXElement?
    let elements: [SnapshotElement]
    let geometry: ScreenshotGeometry?
    let taken: ContinuousClock.Instant
}

/// Per-app state across calls: the AX application element (with a short
/// messaging timeout, so a hung app cannot stall the service) and the last
/// snapshot, whose indexes the next action resolves against.
final class AppSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [pid_t: AppSnapshot] = [:]
    private var appElements: [pid_t: AXElement] = [:]
    /// Seconds an AX call to the target may block before it fails.
    static let messagingTimeout: Float = 0.5

    func appElement(pid: pid_t) -> AXElement {
        lock.withLock {
            if let element = appElements[pid] { return element }
            let element = AXElement(pid: pid)
            element.setMessagingTimeout(Self.messagingTimeout)
            // Chromium and Electron build their accessibility tree only for an
            // assistive client that asks; both flags are no-ops elsewhere.
            element.set("AXManualAccessibility", kCFBooleanTrue)
            element.set("AXEnhancedUserInterface", kCFBooleanTrue)
            appElements[pid] = element
            return element
        }
    }

    func store(_ snapshot: AppSnapshot) { lock.withLock { snapshots[snapshot.app.pid] = snapshot } }
    func snapshot(pid: pid_t) -> AppSnapshot? { lock.withLock { snapshots[pid] } }

    func forget(pid: pid_t) {
        lock.withLock {
            snapshots[pid] = nil
            appElements[pid] = nil
        }
    }
}
