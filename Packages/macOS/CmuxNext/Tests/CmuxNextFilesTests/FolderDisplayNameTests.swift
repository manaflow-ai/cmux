import Foundation
import Testing
@testable import CmuxNextFiles

/// Naming a standard folder (Desktop, Documents, Downloads, ...) never looks inside it: Launch
/// Services' look into `~/Downloads` for its `.localized` marker asked macOS for Downloads in the
/// app's own name whenever a Files pane or its sidebar showed it (docs/cmux-files-host.md).
struct FolderDisplayNameTests {
    @Test func aStandardFolderOfTheHomeIsNamedByTheSystemTableNotTheDisk() throws {
        // A home that does not exist: only the table can name its folders.
        let home = URL(fileURLWithPath: "/nonexistent-cmux-home-\(UUID().uuidString)", isDirectory: true)
        let names = FolderDisplayName(home: home, systemNames: { "[\($0)]" })
        #expect(names.name(of: home.appendingPathComponent("Downloads")) == "[Downloads]")
        #expect(names.name(of: home.appendingPathComponent("Desktop", isDirectory: true)) == "[Desktop]")
        #expect(names.name(of: home.appendingPathComponent("Documents/")) == "[Documents]")
    }

    @Test func otherFoldersAskLaunchServicesAsBefore() throws {
        let temp = try TempFolder()
        let names = FolderDisplayName(home: temp.url, systemNames: { _ in Issue.record("table asked"); return "" })
        let plain = try temp.folder("Projects")
        #expect(names.name(of: plain) == FileManager.default.displayName(atPath: plain.path))
        // A folder named Downloads that is not the home's own is not a standard folder.
        let nested = try temp.folder("Projects/Downloads")
        #expect(names.name(of: nested) == FileManager.default.displayName(atPath: nested.path))
    }

    @Test func theSystemTableNamesEveryStandardFolder() {
        let names = FolderDisplayName(home: URL(fileURLWithPath: "/nonexistent-cmux-home", isDirectory: true))
        for folder in FolderDisplayName.standardFolders {
            #expect(!names.name(of: URL(fileURLWithPath: "/nonexistent-cmux-home/\(folder)")).isEmpty)
        }
    }
}
