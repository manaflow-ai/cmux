/// One terminal's scrollback as a session snapshot stores it.
///
/// A pure persistence value: the app's snapshot and checkpoint code build it
/// after applying the session line and character caps.
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
