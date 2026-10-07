import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Moves a verified partial into its destination directory under a fresh
/// name (exclusive create, then rename over the placeholder; copy when the
/// directory is on another volume).
struct MobilePlacement {
    let source: String
    let directory: String
    let name: String

    func place() throws(MobileDaemonError) -> String {
        let final = try MobileFilePolicy.createUniqueFile(in: directory, name: name)
        if rename(source, final) == 0 { return final }
        guard errno == EXDEV else {
            unlink(final)
            throw MobileDaemonError(code: "files.dest_invalid", message: "could not move the upload")
        }
        let temporary = final + ".cmux-part"
        do {
            try FileManager.default.copyItem(atPath: source, toPath: temporary)
        } catch {
            unlink(final)
            throw MobileDaemonError(code: "files.dest_invalid", message: "could not copy the upload")
        }
        guard rename(temporary, final) == 0 else {
            unlink(temporary)
            unlink(final)
            throw MobileDaemonError(code: "files.dest_invalid", message: "could not move the upload")
        }
        unlink(source)
        return final
    }
}
