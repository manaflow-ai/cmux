import Foundation
import CmuxNextSettings
import Testing

/// `reachesProtectedFolder` finds a protected folder by its identity, not its spelling: the Mac's
/// disk matches `Documentſ` (long s) to Documents, which `lowercased()` does not, and the data
/// volume's path names the same home folder another way.
struct ChatRootValidatorIdentityTests {
    @Test func aProtectedFolderIsFoundWhateverItsSpelling() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("validator-\(UUID().uuidString)/home").path
        try FileManager.default.createDirectory(atPath: made + "/Documents/site", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/code/site", withIntermediateDirectories: true)
        guard let resolved = realpath(made, nil) else { throw CocoaError(.fileNoSuchFile) }
        let home = String(cString: resolved)
        free(resolved)
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let validator = ChatRootValidator(home: home)

        #expect(validator.refusal(home + "/Documentſ/site") == nil, "the spelling check alone misses it")
        #expect(validator.reachesProtectedFolder(home + "/Documentſ/site"))
        #expect(validator.reachesProtectedFolder(home + "/Documents"))
        #expect(validator.reachesProtectedFolder("/System/Volumes/Data" + home + "/Documents/site"))
        #expect(!validator.reachesProtectedFolder(home + "/code/site"))
        #expect(!validator.reachesProtectedFolder(home + "/Desktop/site"), "a protected folder that is not there protects nothing")
    }
}
