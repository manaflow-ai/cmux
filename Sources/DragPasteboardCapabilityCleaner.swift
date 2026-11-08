import AppKit
import Foundation

/// Removes one drag capability while preserving every unrelated representation.
@MainActor
struct DragPasteboardCapabilityCleaner {
    /// Removes `capabilityValue` for `type` only when the pasteboard still owns it.
    ///
    /// - Parameters:
    ///   - type: The internal capability type to remove.
    ///   - capabilityValue: The exact value published by the ended drag.
    ///   - pasteboard: The pasteboard whose residual capability should be removed.
    func remove(
        type: NSPasteboard.PasteboardType,
        capabilityValue: String,
        from pasteboard: NSPasteboard
    ) {
        remove(type: type, matching: { pasteboard.string(forType: type) == capabilityValue }, from: pasteboard)
    }

    /// Removes a data-backed capability while preserving unrelated types.
    func remove(
        type: NSPasteboard.PasteboardType,
        capabilityData: Data,
        from pasteboard: NSPasteboard
    ) {
        remove(type: type, matching: { pasteboard.data(forType: type) == capabilityData }, from: pasteboard)
    }

    /// Removes a value-backed capability only while a second data-backed
    /// capability still identifies the same drag generation.
    ///
    /// AppKit may replace a mirrored `.fileURL` while retaining the private
    /// drag payload. Requiring both values in the same guarded cleanup keeps a
    /// late completion from removing a newer drag of the same path.
    func remove(
        type: NSPasteboard.PasteboardType,
        capabilityValue: String,
        from pasteboard: NSPasteboard,
        requiring markerType: NSPasteboard.PasteboardType,
        markerData: Data
    ) {
        remove(
            type: type,
            matching: {
                pasteboard.string(forType: type) == capabilityValue
                    && (pasteboard.data(forType: markerType) == markerData
                        || pasteboard.string(forType: markerType)
                            .map { Data($0.utf8) } == markerData)
            },
            from: pasteboard
        )
    }

    /// Removes a value-backed capability only while a second string-backed
    /// capability still identifies the same drag generation.
    func remove(
        type: NSPasteboard.PasteboardType,
        capabilityValue: String,
        from pasteboard: NSPasteboard,
        requiring markerType: NSPasteboard.PasteboardType,
        markerValue: String
    ) {
        remove(
            type: type,
            matching: {
                pasteboard.string(forType: type) == capabilityValue
                    && pasteboard.string(forType: markerType) == markerValue
            },
            from: pasteboard
        )
    }

    private func remove(
        type: NSPasteboard.PasteboardType,
        matching stillMatches: () -> Bool,
        from pasteboard: NSPasteboard
    ) {
        guard stillMatches() else { return }
        let changeCount = pasteboard.changeCount
        let preservedItems: [NSPasteboardItem] = {
            if let items = pasteboard.pasteboardItems {
                return items.compactMap { item in
                    let copy = NSPasteboardItem()
                    for itemType in item.types where itemType != type {
                        if let data = item.data(forType: itemType) {
                            copy.setData(data, forType: itemType)
                        } else if let value = item.propertyList(forType: itemType) {
                            copy.setPropertyList(value, forType: itemType)
                        }
                    }
                    return copy.types.isEmpty ? nil : copy
                }
            }

            let copy = NSPasteboardItem()
            for itemType in pasteboard.types ?? [] where itemType != type {
                if let data = pasteboard.data(forType: itemType) {
                    copy.setData(data, forType: itemType)
                } else if let value = pasteboard.propertyList(forType: itemType) {
                    copy.setPropertyList(value, forType: itemType)
                }
            }
            return copy.types.isEmpty ? [] : [copy]
        }()

        // A newer drag may have replaced the capability while the snapshot was
        // being copied. Never clear that newer generation.
        guard pasteboard.changeCount == changeCount,
              stillMatches() else {
            return
        }
        pasteboard.clearContents()
        if !preservedItems.isEmpty {
            pasteboard.writeObjects(preservedItems)
        }
    }
}
