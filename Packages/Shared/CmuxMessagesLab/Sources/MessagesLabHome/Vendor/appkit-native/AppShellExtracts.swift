import AppKit

// Extracted verbatim from appkit-native/Sources/App.swift and Bench.swift at
// 3a53206: the parts of the app shell that the vendored files use. The rest
// of those files (the @main app, the menu bar, the window, capture, bench,
// self test, probes) belongs to the standalone app and is not vendored.
// cmux edits: `bundle: .module` on the strings (the catalog is the
// package's); `MallocCounter.install` is left out (bench only).

/// Strings of the AppKit shell (menus, buttons); the transcript's strings come
/// from the catalyst catalog.
enum NativeStrings {
    static var attach: String { String(localized: "compose.attach", defaultValue: "Add Attachment", table: "AppKitNative", bundle: .module) }
    static var emoji: String { String(localized: "compose.emoji", defaultValue: "Emoji", table: "AppKitNative", bundle: .module) }
    static var chooseImages: String { String(localized: "attach.panel.message", defaultValue: "Choose images to send", table: "AppKitNative", bundle: .module) }
    static var attachPrompt: String { String(localized: "attach.panel.prompt", defaultValue: "Attach", table: "AppKitNative", bundle: .module) }
    static var video: String { String(localized: "header.video", defaultValue: "FaceTime Video", table: "AppKitNative", bundle: .module) }
    /// The name pill: "Contact details for %@".
    static var contactFormat: String { String(localized: "header.contact", defaultValue: "Contact details for %@", table: "AppKitNative", bundle: .module) }
}

extension MessagesWindowView {
    /// Position of the first visible row in the whole history (0 oldest,
    /// 1 newest), for the overlay scroller (the shared thumb's formula).
    var historyFraction: Double {
        let st = store.state
        if st.ui.scroll.pinnedToBottom && st.atNewest { return 1 }
        let n = max(1, st.conversation.messages.count)
        let rowFrac = model.count > 0 ? Double(firstVisibleRow) / Double(model.count) : 1
        let seq = Double(st.windowStart) + rowFrac * Double(n)
        return min(1, seq / max(1, Double(st.total)))
    }
    /// Visible share of the estimated history height.
    var historyProportion: CGFloat {
        let st = store.state
        let loaded = max(1, st.conversation.messages.count)
        let estimated = model.total * CGFloat(max(st.total, loaded)) / CGFloat(loaded)
        return min(1, max(0.02, (anchorY - Fixture.headerHeight) / max(1, estimated)))
    }
}

/// The resolution audit's draw hook (ResolutionAudit.swift; the shim's
/// UIImage.draw reads it). The audit itself is not vendored.
enum ResolutionAudit {
    /// Images drawn above their source size (filled by UIImage.draw).
    static var drawFindings: [[String: Any]] = []
    static var recording = false
}

/// Counts heap allocations on the main thread with libmalloc's `malloc_logger`
/// hook (catalyst/Sources/Bench.swift; the shared window view reads it).
enum MallocCounter {
    static var mainAllocations = 0
}
