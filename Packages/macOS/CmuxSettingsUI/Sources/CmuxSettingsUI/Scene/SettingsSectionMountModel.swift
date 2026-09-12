import SwiftUI

/// A scroll the settings scene applies once its target section is on
/// screen, and re-applies while sections above it are still mounting.
/// Declared at file scope so this plain value stays free of
/// ``SettingsSectionMountModel``'s main-actor isolation.
public struct SettingsSectionScrollTarget: Equatable, Sendable {
    public let section: SettingsSectionID
    public let anchorID: String
    public let anchor: UnitPoint
    /// Navigation generation the request was issued under; a newer
    /// navigation supersedes an older deferred scroll.
    public let generation: Int

    public init(section: SettingsSectionID, anchorID: String, anchor: UnitPoint, generation: Int) {
        self.section = section
        self.anchorID = anchorID
        self.anchor = anchor
        self.generation = generation
    }
}

/// Progressive mounting of the settings window's detail sections
/// (https://github.com/manaflow-ai/cmux/issues/12134).
///
/// ``SettingsWindowRoot`` stacks every section in one eager `VStack` so
/// any search anchor is `scrollTo`-addressable. Materializing all ~19
/// sections (about 300 AppKit-backed controls) in the first synchronous
/// layout pass takes seconds on an Intel Mac, and that pass runs inside
/// `NSWindow(contentViewController:)` before the window is ordered front,
/// so the main thread stalls and the beachball spins before anything is
/// on screen.
///
/// The model keeps the "every mounted anchor exists" guarantee while
/// spreading construction over update passes. The section the window
/// opens on is mounted in the first pass; the scene then mounts one more
/// section per pass, each hopped off the previous section's `onAppear` (a
/// real "that content is in the hierarchy" signal), so input events are
/// serviced between chunks. Navigation to a section that is not mounted
/// yet mounts it immediately and defers the scroll until that section
/// appears.
@MainActor
@Observable
public final class SettingsSectionMountModel {
    /// Detail-stack order of the sections that own a slot. `browserImport`
    /// is an anchor inside the Browser section rather than a section of
    /// its own, so it never appears here.
    public static let displayOrder: [SettingsSectionID] = [
        .account, .app, .terminal, .textBox, .sleepyMode, .mobile, .cloudMachines,
        .networking, .sidebarAppearance, .customSidebars, .betaFeatures, .automation,
        .computerUse, .browser, .globalHotkey, .keyboardShortcuts, .workspaceColors,
        .settingsJSON, .reset,
    ]

    /// The slot that hosts `section`'s content.
    public static func hostSection(for section: SettingsSectionID) -> SettingsSectionID {
        section == .browserImport ? .browser : section
    }

    /// Sections mounted progressively, in detail-stack order. Sections
    /// outside this list are always rendered eagerly by the scene.
    public let order: [SettingsSectionID]
    public private(set) var mounted: Set<SettingsSectionID>
    /// The chain's outstanding mount: the next section mounts only after
    /// this one has appeared, so exactly one section is under construction
    /// per update pass.
    private var awaitingAppearance: SettingsSectionID?
    private var queue: [SettingsSectionID]
    /// Navigation waiting for its section to appear before scrolling.
    public private(set) var deferredScroll: SettingsSectionScrollTarget?
    /// Most recent navigation; re-applied when a section above it mounts
    /// so the viewport does not drift while placeholders grow into content.
    public private(set) var pinnedScroll: SettingsSectionScrollTarget?

    /// - Parameters:
    ///   - initial: The section mounted in the first (synchronous) pass.
    ///   - order: Sections mounted progressively, in detail-stack order.
    public init(initial: SettingsSectionID, order: [SettingsSectionID] = SettingsSectionMountModel.displayOrder) {
        self.order = order
        let host = Self.hostSection(for: initial)
        let first = order.contains(host) ? host : order.first
        mounted = Set(first.map { [$0] } ?? [])
        awaitingAppearance = first
        queue = order.filter { $0 != first }
    }

    /// Whether every section in ``order`` has been mounted and the last
    /// one mounted has appeared, i.e. nothing is still under construction.
    public var isComplete: Bool { queue.isEmpty && awaitingAppearance == nil }

    /// Whether `section`'s content is present in the detail stack.
    public func isMounted(_ section: SettingsSectionID) -> Bool {
        let host = Self.hostSection(for: section)
        return !order.contains(host) || mounted.contains(host)
    }

    /// Mounts `section` now when it is still a placeholder.
    /// - Returns: `true` when the section was already mounted.
    @discardableResult
    public func ensureMounted(_ section: SettingsSectionID) -> Bool {
        let host = Self.hostSection(for: section)
        if isMounted(host) { return true }
        mount(host)
        return false
    }

    /// Advances the chain after `section`'s content appeared.
    /// - Returns: The section mounted next, or `nil` when the appearance
    ///   was not the chain's outstanding mount or nothing is left.
    public func sectionDidAppear(_ section: SettingsSectionID) -> SettingsSectionID? {
        guard section == awaitingAppearance else { return nil }
        awaitingAppearance = nil
        guard let next = queue.first else { return nil }
        mount(next)
        awaitingAppearance = next
        return next
    }

    /// Removes a section that is unavailable before it appears and advances
    /// the progressive mount chain when that section was outstanding.
    ///
    /// - Parameter section: The unavailable section to omit.
    /// - Returns: The next section mounted, or `nil` when no advancement was needed.
    @discardableResult
    public func skip(_ section: SettingsSectionID) -> SettingsSectionID? {
        let host = Self.hostSection(for: section)
        queue.removeAll { $0 == host }
        guard awaitingAppearance == host else { return nil }
        awaitingAppearance = nil
        guard let next = queue.first else { return nil }
        mount(next)
        awaitingAppearance = next
        return next
    }

    /// Records the navigation the viewport should stay on.
    public func pin(_ target: SettingsSectionScrollTarget) {
        pinnedScroll = target
    }

    /// Defers `target` until its section appears (replacing any older
    /// deferred scroll).
    public func deferScroll(_ target: SettingsSectionScrollTarget) {
        deferredScroll = target
    }

    /// Consumes the deferred scroll owed to `section`, if any.
    public func takeDeferredScroll(for section: SettingsSectionID) -> SettingsSectionScrollTarget? {
        guard let target = deferredScroll, Self.hostSection(for: target.section) == section else { return nil }
        deferredScroll = nil
        return target
    }

    public func cancelDeferredScroll() {
        deferredScroll = nil
    }

    /// Whether `section` sits above `other` in the detail stack, i.e.
    /// mounting it shifts `other` down.
    public func isAbove(_ section: SettingsSectionID, _ other: SettingsSectionID) -> Bool {
        guard
            let index = order.firstIndex(of: Self.hostSection(for: section)),
            let otherIndex = order.firstIndex(of: Self.hostSection(for: other))
        else { return false }
        return index < otherIndex
    }

    private func mount(_ section: SettingsSectionID) {
        mounted.insert(section)
        queue.removeAll { $0 == section }
    }
}
