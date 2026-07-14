/// A structured, localized screen-level changes failure.
struct ChangesErrorSnapshot: Sendable, Equatable {
    /// Broad recovery category.
    enum Kind: Sendable, Equatable {
        /// Authentication or authorization failed.
        case authentication
        /// Connected Mac lacks the native changes capability.
        case capability
        /// Requested baseline could not be resolved.
        case baseline
        /// Transport or unclassified failure.
        case general
    }

    /// Failure category.
    let kind: Kind
    /// Localized title.
    let title: String
    /// Localized recovery-oriented detail.
    let message: String

    /// Creates a structured failure snapshot.
    init(kind: Kind, title: String, message: String) {
        self.kind = kind
        self.title = title
        self.message = message
    }
}
