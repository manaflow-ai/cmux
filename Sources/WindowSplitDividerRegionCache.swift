import AppKit

@MainActor
final class WindowSplitDividerRegionCache {
    typealias HostedContentClassifier = (NSSplitView) -> Bool

    private var generation: UInt64 = 0
    private var cachedGeneration: UInt64?
    private weak var cachedRootView: NSView?
    private var cachedRegions: [WindowSplitDividerRegion] = []
    private var cachedSplitSourceViews = NSPointerArray.weakObjects()
    private var cachedSplitSourceCounts: [ObjectIdentifier: UInt64] = [:]
    private var cachedSubviewSnapshotViews = NSPointerArray.weakObjects()
    private var cachedSubviewSnapshotIDs: [[ObjectIdentifier]] = []
    private var cachedSubviewSnapshotHiddenStates: [Bool] = []
    var buildCount = 0

    func invalidate() {
        generation &+= 1
        cachedGeneration = nil
        cachedRootView = nil
        cachedRegions.removeAll(keepingCapacity: true)
        cachedSplitSourceViews = NSPointerArray.weakObjects()
        cachedSplitSourceCounts.removeAll(keepingCapacity: true)
        cachedSubviewSnapshotViews = NSPointerArray.weakObjects()
        cachedSubviewSnapshotIDs.removeAll(keepingCapacity: true)
        cachedSubviewSnapshotHiddenStates.removeAll(keepingCapacity: true)
    }

    func regions(
        in rootView: NSView,
        window: NSWindow?,
        hostedContentClassifier: HostedContentClassifier = { _ in false }
    ) -> [WindowSplitDividerRegion] {
        if let regions = refreshedCachedRegions(
            in: rootView,
            window: window
        ) {
            return regions
        }

        var regions: [WindowSplitDividerRegion] = []
        let splitSourceViews = NSPointerArray.weakObjects()
        var splitSourceCounts: [ObjectIdentifier: UInt64] = [:]
        let subviewSnapshotViews = NSPointerArray.weakObjects()
        var subviewSnapshotIDs: [[ObjectIdentifier]] = []
        var subviewSnapshotHiddenStates: [Bool] = []
        Self.collectRegions(
            in: rootView,
            into: &regions,
            splitSourceViews: splitSourceViews,
            splitSourceCounts: &splitSourceCounts,
            subviewSnapshotViews: subviewSnapshotViews,
            subviewSnapshotIDs: &subviewSnapshotIDs,
            subviewSnapshotHiddenStates: &subviewSnapshotHiddenStates,
            hostedContentClassifier: hostedContentClassifier
        )
        cachedRegions = regions
        cachedSplitSourceViews = splitSourceViews
        cachedSplitSourceCounts = splitSourceCounts
        cachedSubviewSnapshotViews = subviewSnapshotViews
        cachedSubviewSnapshotIDs = subviewSnapshotIDs
        cachedSubviewSnapshotHiddenStates = subviewSnapshotHiddenStates
        cachedRootView = rootView
        cachedGeneration = generation
#if DEBUG
        buildCount += 1
#endif
        return regions
    }

    private func refreshedCachedRegions(
        in rootView: NSView,
        window: NSWindow?
    ) -> [WindowSplitDividerRegion]? {
        guard cachedGeneration == generation,
              cachedRootView === rootView,
              let window,
              rootView.window === window,
              !Self.isHiddenOrAncestorHidden(rootView) else {
            return nil
        }
        guard Self.subviewSnapshotsAreCurrent(
            views: cachedSubviewSnapshotViews,
            subviewIDs: cachedSubviewSnapshotIDs,
            hiddenStates: cachedSubviewSnapshotHiddenStates
        ) else {
            return nil
        }

        for index in cachedRegions.indices {
            let cached = cachedRegions[index]
            guard let splitView = cached.splitView,
                  splitView.window === window,
                  (splitView === rootView || splitView.isDescendant(of: rootView)),
                  !Self.isHiddenOrAncestorHidden(splitView),
                  let refreshed = Self.region(
                    in: splitView,
                    dividerIndex: cached.dividerIndex,
                    isInHostedContent: cached.isInHostedContent
                  ) else {
                return nil
            }
            cachedRegions[index] = refreshed
        }
        for index in 0..<cachedSplitSourceViews.count {
            guard let splitViewPointer = cachedSplitSourceViews.pointer(at: index) else {
                return nil
            }
            let splitView = Unmanaged<NSSplitView>.fromOpaque(splitViewPointer).takeUnretainedValue()
            guard
                let encodedCounts = cachedSplitSourceCounts[ObjectIdentifier(splitView)],
                splitView.window === window,
                (splitView === rootView || splitView.isDescendant(of: rootView)) else {
                return nil
            }
            let source = Self.splitSourceCounts(from: encodedCounts)
            let dividerCount = Self.dividerCount(in: splitView)
            guard dividerCount == source.dividerCount else { return nil }
            guard !Self.isHiddenOrAncestorHidden(splitView) else { continue }
            if source.validRegionCount < dividerCount,
               Self.regionCount(in: splitView) != source.validRegionCount {
                return nil
            }
        }
        return cachedRegions
    }

    private static func collectRegions(
        in view: NSView,
        into result: inout [WindowSplitDividerRegion],
        splitSourceViews: NSPointerArray,
        splitSourceCounts: inout [ObjectIdentifier: UInt64],
        subviewSnapshotViews: NSPointerArray,
        subviewSnapshotIDs: inout [[ObjectIdentifier]],
        subviewSnapshotHiddenStates: inout [Bool],
        hostedContentClassifier: HostedContentClassifier
    ) {
        let subviews = view.subviews
        let isHidden = view.isHidden
        subviewSnapshotViews.addPointer(Unmanaged.passUnretained(view).toOpaque())
        subviewSnapshotIDs.append(isHidden ? [] : subviews.map { ObjectIdentifier($0) })
        subviewSnapshotHiddenStates.append(isHidden)

        if let splitView = view as? NSSplitView {
            let dividerCount = dividerCount(in: splitView)
            var validRegionCount = 0
            if !isHiddenOrAncestorHidden(splitView) {
                let isInHostedContent = hostedContentClassifier(splitView)
                for dividerIndex in 0..<dividerCount {
                    guard let region = region(
                        in: splitView,
                        dividerIndex: dividerIndex,
                        isInHostedContent: isInHostedContent
                    ) else { continue }
                    validRegionCount += 1
                    result.append(region)
                }
            }
            splitSourceViews.addPointer(Unmanaged.passUnretained(splitView).toOpaque())
            splitSourceCounts[ObjectIdentifier(splitView)] = encodedSplitSourceCounts(
                dividerCount: dividerCount,
                validRegionCount: validRegionCount
            )
        }
        guard !isHidden else { return }

        for subview in subviews.reversed() {
            collectRegions(
                in: subview,
                into: &result,
                splitSourceViews: splitSourceViews,
                splitSourceCounts: &splitSourceCounts,
                subviewSnapshotViews: subviewSnapshotViews,
                subviewSnapshotIDs: &subviewSnapshotIDs,
                subviewSnapshotHiddenStates: &subviewSnapshotHiddenStates,
                hostedContentClassifier: hostedContentClassifier
            )
        }
    }

    private static func subviewSnapshotsAreCurrent(
        views: NSPointerArray,
        subviewIDs: [[ObjectIdentifier]],
        hiddenStates: [Bool]
    ) -> Bool {
        guard views.count == subviewIDs.count, views.count == hiddenStates.count else { return false }
        for index in 0..<views.count {
            guard let pointer = views.pointer(at: index) else { return false }
            let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
            guard view.isHidden == hiddenStates[index] else { return false }
            guard !hiddenStates[index] else { continue }
            guard currentSubviews(in: view, match: subviewIDs[index]) else { return false }
        }
        return true
    }

    private static func currentSubviews(in view: NSView, match subviewIDs: [ObjectIdentifier]) -> Bool {
        let currentSubviews = view.subviews
        guard currentSubviews.count == subviewIDs.count else { return false }
        for index in currentSubviews.indices {
            guard ObjectIdentifier(currentSubviews[index]) == subviewIDs[index] else { return false }
        }
        return true
    }

    private static func encodedSplitSourceCounts(dividerCount: Int, validRegionCount: Int) -> UInt64 {
        (UInt64(UInt32(dividerCount)) << 32) | UInt64(UInt32(validRegionCount))
    }

    private static func splitSourceCounts(from encoded: UInt64) -> (dividerCount: Int, validRegionCount: Int) {
        (dividerCount: Int(encoded >> 32), validRegionCount: Int(encoded & 0xffff_ffff))
    }

    private static func dividerCount(in splitView: NSSplitView) -> Int {
        max(0, splitView.arrangedSubviews.count - 1)
    }

    private static func regionCount(in splitView: NSSplitView) -> Int {
        var count = 0
        for dividerIndex in 0..<dividerCount(in: splitView) {
            if region(in: splitView, dividerIndex: dividerIndex, isInHostedContent: false) != nil {
                count += 1
            }
        }
        return count
    }

    private static func region(
        in splitView: NSSplitView,
        dividerIndex: Int,
        isInHostedContent: Bool
    ) -> WindowSplitDividerRegion? {
        guard dividerIndex >= 0,
              dividerIndex + 1 < splitView.arrangedSubviews.count else {
            return nil
        }

        let first = splitView.arrangedSubviews[dividerIndex].frame
        let second = splitView.arrangedSubviews[dividerIndex + 1].frame
        let thickness = splitView.dividerThickness
        let dividerRect: NSRect
        if splitView.isVertical {
            // Keep divider hit-testing active even when one side is nearly collapsed,
            // so users can drag the divider back out from the border.
            // But ignore transient states where both panes are effectively 0-width.
            guard first.width > 1 || second.width > 1 else { return nil }
            let x = max(0, first.maxX)
            dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
        } else {
            // Same behavior for horizontal splits with a near-zero-height pane.
            guard first.height > 1 || second.height > 1 else { return nil }
            let y = max(0, first.maxY)
            dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
        }
        let rectInWindow = splitView.convert(dividerRect, to: nil)
        let splitBoundsInWindow = splitView.convert(splitView.bounds, to: nil)
        guard rectInWindow.width > 0,
              rectInWindow.height > 0,
              splitBoundsInWindow.width > 0,
              splitBoundsInWindow.height > 0 else { return nil }
        return WindowSplitDividerRegion(
            rectInWindow: rectInWindow,
            splitBoundsInWindow: splitBoundsInWindow,
            isVertical: splitView.isVertical,
            isInHostedContent: isInHostedContent,
            splitView: splitView,
            dividerIndex: dividerIndex
        )
    }

    private static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let ancestor = current {
            if ancestor.isHidden { return true }
            current = ancestor.superview
        }
        return false
    }
}
