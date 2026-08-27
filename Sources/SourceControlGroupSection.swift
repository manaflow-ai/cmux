import Foundation

/// One non-empty status group and its immutable resource rows.
struct SourceControlGroupSection: Identifiable {
    let group: SourceControlGroup
    let resources: [SourceControlResourceRow]

    var id: SourceControlGroup { group }
}
