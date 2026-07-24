import Foundation

/// The file status fields needed for git index dirty detection.
struct GitFileStatus: Equatable, Sendable {
    let mode: UInt32
    let size: Int64
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64

    init(mode: UInt32, size: Int64, mtimeSeconds: Int64, mtimeNanoseconds: Int64) {
        self.mode = mode
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
    }

    init(statValue: stat) {
        self.init(
            mode: UInt32(statValue.st_mode),
            size: Int64(statValue.st_size),
            mtimeSeconds: Int64(statValue.st_mtimespec.tv_sec),
            mtimeNanoseconds: Int64(statValue.st_mtimespec.tv_nsec)
        )
    }

    var indexStatSignature: GitIndexStatSignature {
        GitIndexStatSignature(
            size: size,
            mtimeSeconds: mtimeSeconds,
            mtimeNanoseconds: mtimeNanoseconds
        )
    }
}
