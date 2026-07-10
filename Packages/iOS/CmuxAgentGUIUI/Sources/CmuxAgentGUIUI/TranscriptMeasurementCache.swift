#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

/// Caches deterministic transcript row height estimates by content and environment.
public actor TranscriptMeasurementCache {
    private struct CacheEntry: Sendable {
        let height: CGFloat
        let lastAccess: UInt64
    }

    private static let maximumEntryCount = 2_000
    private var entries: [TranscriptMeasurementKey: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0

    /// Creates an empty measurement cache.
    public init() {}

    func height(
        for row: TranscriptRow,
        width: CGFloat,
        environment: TranscriptMeasurementEnvironment
    ) -> CGFloat {
        accessCounter += 1
        let key = TranscriptMeasurementKey(
            contentHash: row.measurementContentHash,
            widthBucket: Int((width / 8).rounded(.toNearestOrAwayFromZero)),
            contentSizeCategory: environment.contentSizeCategory,
            userInterfaceStyle: environment.userInterfaceStyle
        )
        if let cached = entries[key] {
            entries[key] = CacheEntry(height: cached.height, lastAccess: accessCounter)
            return cached.height
        }
        let measured = Self.measure(
            row: row,
            width: width,
            contentSizeCategory: UIContentSizeCategory(rawValue: environment.contentSizeCategory)
        )
        entries[key] = CacheEntry(height: measured, lastAccess: accessCounter)
        if entries.count > Self.maximumEntryCount,
           let leastRecentlyUsedKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: leastRecentlyUsedKey)
        }
        return measured
    }

    private static func measure(
        row: TranscriptRow,
        width: CGFloat,
        contentSizeCategory: UIContentSizeCategory
    ) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: traits
        )
        let horizontalPadding: CGFloat = row.isProse ? 102 : 40
        let verticalPadding: CGFloat = row.isProse ? 24 : 16
        let constrainedWidth = max(80, width - horizontalPadding)
        let textStorage = NSTextStorage(string: row.measurementText, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(
            width: constrainedWidth,
            height: .greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        return max(36, ceil(layoutManager.usedRect(for: textContainer).height + verticalPadding))
    }
}
#endif
