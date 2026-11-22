import Foundation
import Testing
@testable import CmuxNextBrowser

/// The shim ABI identity is the SHA-256 of the shim header, derived the same
/// way on both sides, so an interface change needs no hand-bumped number.
@Suite struct CEFShimABITests {
    static let header = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h")

    /// The bundled resource is the header in the source tree.
    @Test func bundledIdentityIsTheSourceHeaderHash() throws {
        let source = try Data(contentsOf: Self.header)
        #expect(CEFShimABI.bundledIdentity() == CEFShimABI.identity(of: source))
    }

    /// Swift's identity equals what build-cef-shim.sh compiles into the shim
    /// (`shasum -a 256 <header>`).
    @Test func identityMatchesTheBuildScriptDerivation() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", Self.header.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let shasum = try #require(output.split(separator: " ").first.map(String.init))
        #expect(CEFShimABI.bundledIdentity() == shasum)
        #expect(shasum.count == 64)
    }

    /// Two different edits of the header, and their merge, all differ.
    @Test func anyEditChangesTheIdentity() {
        let base = Data("int cmux_shim_a(void);\n".utf8)
        let left = Data("int cmux_shim_a(void);\nint cmux_shim_b(void);\n".utf8)
        let right = Data("int cmux_shim_a(int);\n".utf8)
        let merged = Data("int cmux_shim_a(int);\nint cmux_shim_b(void);\n".utf8)
        let ids = Set([base, left, right, merged].map(CEFShimABI.identity(of:)))
        #expect(ids.count == 4)
    }

    @Test func mismatchOrMissingIdentityRefusesTheShim() {
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "a", found: "b")) {
            try CEFShimLibrary.checkABI(expected: "a", found: "b")
        }
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "missing", found: "b")) {
            try CEFShimLibrary.checkABI(expected: nil, found: "b")
        }
        #expect(throws: Never.self) { try CEFShimLibrary.checkABI(expected: "a", found: "a") }
    }
}
