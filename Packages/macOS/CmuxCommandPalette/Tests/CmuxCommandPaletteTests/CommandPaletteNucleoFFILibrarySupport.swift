import Darwin
import Foundation

@testable import CmuxCommandPalette

struct FFICandidateSpan {
    let titleOffset: Int
    let titleLength: Int
    let searchOffset: Int
    let searchLength: Int
    let rank: Int32
}

struct FFIMatch {
    var index: Int
    var score: Double
    var rank: Int32
}

final class NucleoLibrary {
    private static let supportedVersion: UInt32 = 2
    private static let libraryFileName = "libcmux_command_palette_nucleo_ffi.dylib"

    typealias CreateIndex = @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeRawPointer?,
        Int
    ) -> OpaquePointer?
    typealias DestroyIndex = @convention(c) (OpaquePointer?) -> Void
    typealias SearchIndex = @convention(c) (
        OpaquePointer?,
        UnsafePointer<UInt8>?,
        Int,
        Int,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutablePointer<Int>?
    ) -> Int32
    typealias Version = @convention(c) () -> UInt32

    let handle: UnsafeMutableRawPointer
    let createIndex: CreateIndex
    let destroyIndex: DestroyIndex
    let searchIndex: SearchIndex
    let version: Version

    /// Returns nil when the nucleo FFI dylib has not been built or bundled in
    /// this environment (the XCTest port threw XCTSkip in that case). Throws
    /// only for real load failures (dlopen/dlsym/version errors).
    static func loadIfAvailable() throws -> NucleoLibrary? {
        let environment = ProcessInfo.processInfo.environment
        let paths = defaultLibraryPaths(environment: environment)
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        return try NucleoLibrary(path: path)
    }

    private init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw NSError(
                domain: "CommandPaletteNucleoFFITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "dlopen failed: \(Self.dlerrorText())"]
            )
        }
        self.handle = handle
        self.createIndex = try Self.symbol(
            "cmux_nucleo_index_create",
            from: handle,
            as: CreateIndex.self
        )
        self.destroyIndex = try Self.symbol(
            "cmux_nucleo_index_destroy",
            from: handle,
            as: DestroyIndex.self
        )
        self.searchIndex = try Self.symbol(
            "cmux_nucleo_index_search",
            from: handle,
            as: SearchIndex.self
        )
        self.version = try Self.symbol(
            "cmux_nucleo_ffi_version",
            from: handle,
            as: Version.self
        )
        let resolvedVersion = self.version()
        guard resolvedVersion == Self.supportedVersion else {
            dlclose(handle)
            throw NSError(
                domain: "CommandPaletteNucleoFFITests",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: "unsupported cmux_nucleo_ffi_version \(resolvedVersion)"
                ]
            )
        }
    }

    private static func defaultLibraryPaths(environment: [String: String]) -> [String] {
        var paths: [String] = []
        if let environmentPath = environment["CMUX_NUCLEO_FFI_LIB"], !environmentPath.isEmpty {
            paths.append(environmentPath)
        }
        if let privateFrameworksPath = Bundle.main.privateFrameworksPath {
            paths.append(
                URL(fileURLWithPath: privateFrameworksPath)
                    .appendingPathComponent(libraryFileName)
                    .path
            )
        }

        // This file lives at Packages/macOS/CmuxCommandPalette/Tests/CmuxCommandPaletteTests/,
        // so five deletions reach the repo root (which contains Native/CommandPaletteNucleoFFI/).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let crateTarget = sourceRoot.appendingPathComponent("Native/CommandPaletteNucleoFFI/target")
        paths.append(
            crateTarget
                .appendingPathComponent("cmux-nucleo-ffi")
                .appendingPathComponent(libraryFileName)
                .path
        )
        paths.append(
            crateTarget
                .appendingPathComponent("release")
                .appendingPathComponent(libraryFileName)
                .path
        )
#if arch(arm64)
        paths.append(
            crateTarget
                .appendingPathComponent("aarch64-apple-darwin/release")
                .appendingPathComponent(libraryFileName)
                .path
        )
#elseif arch(x86_64)
        paths.append(
            crateTarget
                .appendingPathComponent("x86_64-apple-darwin/release")
                .appendingPathComponent(libraryFileName)
                .path
        )
#endif
        return paths
    }

    deinit {
        dlclose(handle)
    }

    private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as _: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw NSError(
                domain: "CommandPaletteNucleoFFITests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "dlsym(\(name)) failed: \(dlerrorText())"]
            )
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func dlerrorText() -> String {
        guard let error = dlerror() else { return "unknown error" }
        return String(cString: error)
    }
}

final class NucleoIndex {
    let library: NucleoLibrary
    let pointer: OpaquePointer
    let entries: [FixtureEntry]

    init(library: NucleoLibrary, entries: [FixtureEntry]) throws {
        self.library = library
        self.entries = entries

        var blob: [UInt8] = []
        var spans: [FFICandidateSpan] = []
        blob.reserveCapacity(entries.reduce(0) { total, entry in
            total + entry.title.utf8.count + entry.searchableTexts.reduce(0) { $0 + $1.utf8.count + 1 }
        })
        spans.reserveCapacity(entries.count)

        for entry in entries {
            let titleOffset = blob.count
            blob.append(contentsOf: entry.title.utf8)
            let titleLength = blob.count - titleOffset

            let searchOffset = blob.count
            blob.append(contentsOf: entry.searchableTexts.joined(separator: "\n").utf8)
            let searchLength = blob.count - searchOffset

            spans.append(
                FFICandidateSpan(
                    titleOffset: titleOffset,
                    titleLength: titleLength,
                    searchOffset: searchOffset,
                    searchLength: searchLength,
                    rank: Int32(entry.rank)
                )
            )
        }

        guard let pointer = blob.withUnsafeBufferPointer({ blobBuffer in
            spans.withUnsafeBufferPointer { spanBuffer in
                library.createIndex(
                    blobBuffer.baseAddress,
                    blobBuffer.count,
                    UnsafeRawPointer(spanBuffer.baseAddress),
                    spanBuffer.count
                )
            }
        }) else {
            throw NSError(
                domain: "CommandPaletteNucleoFFITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "cmux_nucleo_index_create returned null"]
            )
        }
        self.pointer = pointer
    }

    deinit {
        library.destroyIndex(pointer)
    }

    func search(query: String, limit: Int) throws -> [NucleoResult] {
        var matches = Array(
            repeating: FFIMatch(index: 0, score: 0, rank: 0),
            count: max(1, limit)
        )
        var count = 0
        let queryBytes = Array(query.utf8)
        let status = queryBytes.withUnsafeBufferPointer { queryBuffer in
            matches.withUnsafeMutableBufferPointer { matchBuffer in
                library.searchIndex(
                    pointer,
                    queryBuffer.baseAddress,
                    queryBuffer.count,
                    limit,
                    UnsafeMutableRawPointer(matchBuffer.baseAddress),
                    matchBuffer.count,
                    &count
                )
            }
        }
        guard status == 0 else {
            throw NSError(
                domain: "CommandPaletteNucleoFFITests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "cmux_nucleo_index_search failed with \(status)"]
            )
        }

        guard count >= 0, count <= matches.count, count <= limit else {
            throw NSError(
                domain: "CommandPaletteNucleoFFITests",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "cmux_nucleo_index_search returned invalid count \(count) for limit \(limit)"
                ]
            )
        }

        return try matches.prefix(count).map { match in
            guard entries.indices.contains(match.index) else {
                throw NSError(
                    domain: "CommandPaletteNucleoFFITests",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey: "cmux_nucleo_index_search returned invalid index \(match.index)"
                    ]
                )
            }
            let entry = entries[match.index]
            return NucleoResult(
                id: entry.id,
                rank: Int(match.rank),
                title: entry.title,
                score: match.score
            )
        }
    }
}
