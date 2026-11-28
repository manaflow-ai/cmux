/// The bounded lifecycle operation reported for one Iroh connection path.
///
/// Raw values are stable diagnostic payload vocabulary. Append new cases;
/// never renumber an existing case.
public enum CmxIrohConnectionPathEventKind: Int, Sendable, Equatable {
    /// A new path opened.
    case opened = 1
    /// An existing path closed.
    case closed = 2
    /// A path became selected for application data.
    case selected = 3
    /// The watcher dropped one or more path events.
    case lagged = 4
}
