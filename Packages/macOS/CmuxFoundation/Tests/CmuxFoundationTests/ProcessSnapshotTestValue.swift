final class ProcessSnapshotTestValue: Sendable {
    let generation: Int
    let fields: ProcessSnapshotTestFields
    init(_ generation: Int, fields: ProcessSnapshotTestFields = []) {
        self.generation = generation
        self.fields = fields
    }
}
