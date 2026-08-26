import AppKit
import Foundation

/// Removes one drag capability while preserving every unrelated representation.
@MainActor
struct DragPasteboardCapabilityCleaner {
    /// Creates a capability cleaner for AppKit drag pasteboards.
    init() {}

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
