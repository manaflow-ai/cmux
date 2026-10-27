import Foundation
import Testing
@testable import CmuxNextFiles

/// The type registry seam behind ``FileOpenKind`` and ``DirectoryLister/isPackage(_:types:)``: the
/// names cmux lists itself never reach it, and its answer decides the rest.
struct FileTypeRegistryTests {
    /// A registry with fixed answers that records what it was asked.
    final class FixedTypes: FileTypeRegistry, @unchecked Sendable { // crash-allow: one test's fake, used on one task
        var asked: [String] = []
        let packages: Set<String>
        let answers: [String: FileTypeContent]

        init(packages: Set<String> = [], answers: [String: FileTypeContent] = [:]) {
            self.packages = packages
            self.answers = answers
        }

        func isPackage(pathExtension: String) -> Bool {
            asked.append(pathExtension)
            return packages.contains(pathExtension)
        }

        func content(pathExtension: String) -> FileTypeContent {
            asked.append(pathExtension)
            return answers[pathExtension] ?? .undeclared
        }
    }

    @Test func listedNamesNeverAskTheRegistry() {
        let types = FixedTypes(answers: ["md": .other, "html": .other, "png": .other, "ts": .other])
        #expect(FileOpenKind(fileName: "README.md", isDirectory: false, isPackage: false, types: types) == .markdown)
        #expect(FileOpenKind(fileName: "index.html", isDirectory: false, isPackage: false, types: types) == .web)
        #expect(FileOpenKind(fileName: "shot.png", isDirectory: false, isPackage: false, types: types) == .preview)
        #expect(FileOpenKind(fileName: "main.ts", isDirectory: false, isPackage: false, types: types) == .editor)
        #expect(FileOpenKind(fileName: "Makefile", isDirectory: false, isPackage: false, types: types) == .editor)
        #expect(types.asked.isEmpty)
    }

    @Test func theRegistryDecidesOtherExtensions() {
        let types = FixedTypes(answers: ["docx": .other, "cfgx": .text])
        #expect(FileOpenKind(fileName: "Report.DOCX", isDirectory: false, isPackage: false, types: types) == .other)
        #expect(FileOpenKind(fileName: "app.cfgx", isDirectory: false, isPackage: false, types: types) == .editor)
        // An extension nobody declared is most often code.
        #expect(FileOpenKind(fileName: "mod.zz", isDirectory: false, isPackage: false, types: types) == .editor)
        #expect(types.asked == ["docx", "cfgx", "zz"])
    }

    @Test func packagesComeFromTheRegistryByLowercasedExtension() {
        let types = FixedTypes(packages: ["bundle", "rtfd"])
        #expect(DirectoryLister.isPackage("Thing.Bundle", types: types))
        #expect(DirectoryLister.isPackage("Notes.rtfd", types: types))
        #expect(!DirectoryLister.isPackage("v1.2", types: types))
        #expect(types.asked == ["bundle", "rtfd", "2"])
    }

    /// The system registry knows the everyday types the same way on every platform cmux builds for.
    @Test(arguments: [
        ("json", FileTypeContent.text), ("txt", .text), ("sh", .text), ("xml", .text), ("yaml", .text),
        ("zip", .other), ("docx", .other), ("dmg", .other),
    ])
    func theSystemRegistryKnowsCommonTypes(ext: String, expected: FileTypeContent) {
        #expect(SystemFileTypes().content(pathExtension: ext) == expected)
    }

    @Test func theSystemRegistryKnowsApps() {
        #expect(SystemFileTypes().isPackage(pathExtension: "app"))
        #expect(!SystemFileTypes().isPackage(pathExtension: "txt"))
        #expect(!SystemFileTypes().isPackage(pathExtension: ""))
    }
}
