import Foundation

/// Descriptor-based read outcome, separating type/size refusal from I/O failure.
enum SessionSnapshotFileRead {
    case data(Data)
    case notRegular
    case tooLarge
    case unreadable
}
