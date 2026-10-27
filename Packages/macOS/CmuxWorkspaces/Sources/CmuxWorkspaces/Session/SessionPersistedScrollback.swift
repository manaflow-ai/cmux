public import Foundation

/// One terminal's scrollback as a session snapshot stores it, and as the
/// in-memory restore cache remembers it.
///
/// Text and truncation travel together. A nil `text` means there is nothing
/// to store, and the cache removes that panel instead of keeping a marker
/// with no tail.
public struct SessionPersistedScrollback: Equatable, Sendable {
    /// The bounded scrollback tail. Nil when there is nothing to store.
    public let text: String?
    /// True when the caps dropped older output from `text`.
    public let wasTruncated: Bool

    /// Creates a stored scrollback value.
    ///
    /// - Parameters:
    ///   - text: The bounded scrollback tail, or nil.
    ///   - wasTruncated: Whether older output was dropped.
    public init(text: String?, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

extension Dictionary where Key == UUID, Value == SessionPersistedScrollback {
    /// Stores `text` and `wasTruncated` as one entry, or removes `panelId`
    /// when `text` is nil.
    ///
    /// - Parameters:
    ///   - text: The bounded scrollback tail. Nil clears the panel.
    ///   - panelId: The terminal panel the tail belongs to.
    ///   - wasTruncated: Whether older output was dropped from `text`.
    public mutating func rememberRestoredScrollback(
        _ text: String?,
        for panelId: UUID,
        wasTruncated: Bool
    ) {
        if let text {
            self[panelId] = SessionPersistedScrollback(text: text, wasTruncated: wasTruncated)
        } else {
            removeValue(forKey: panelId)
        }
    }
}
