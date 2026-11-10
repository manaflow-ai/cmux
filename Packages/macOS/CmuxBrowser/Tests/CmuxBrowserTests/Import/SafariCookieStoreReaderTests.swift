import Foundation
import Testing

@testable import CmuxBrowser

/// One read failure as the filesystem reports it, and how the reader should classify it.
struct ReadFailureCase: Sendable, CustomTestStringConvertible {
    let domain: String
    let code: Int
    let underlyingDomain: String?
    let underlyingCode: Int?
    let expected: SafariCookieStoreErrorKind

    var error: NSError {
        var userInfo: [String: Any] = [:]
        if let underlyingDomain, let underlyingCode {
            userInfo[NSUnderlyingErrorKey] = NSError(domain: underlyingDomain, code: underlyingCode)
        }
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }

    var testDescription: String {
        let underlying = underlyingDomain.map { " wrapping \($0) \(underlyingCode ?? 0)" } ?? ""
        return "\(domain) \(code)\(underlying)"
    }
}

/// Lookup, fallback and failure reporting for Safari's cookie store, with the
/// filesystem replaced by a closure so every error path is reachable.
@Suite struct SafariCookieStoreReaderTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private var containerStore: URL {
        home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }
    private var legacyStore: URL {
        home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
    }
    private let defaultProfile = InstalledBrowserProfile(
        displayName: "Default",
        rootURL: URL(fileURLWithPath: "/Users/tester/Library/Safari", isDirectory: true),
        isDefault: true
    )

    private static let missing = CocoaError(.fileReadNoSuchFile)
    private static let denied = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.fileReadNoPermission.rawValue,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
    )
    private static let damaged = CocoaError(.fileReadCorruptFile)

    /// A reader whose files are `contents`; any other path reads as missing.
    private func reader(_ contents: [URL: Result<Data, any Error>]) -> SafariCookieStoreReader {
        let snapshot = contents.mapValues { result -> Result<Data, NSError> in
            result.mapError { $0 as NSError }
        }
        return SafariCookieStoreReader(homeDirectory: home) { url in
            guard let result = snapshot[url] else { throw Self.missing }
            return try result.get()
        }
    }

    /// Reads the container store first.
    @Test func readsTheContainerStoreFirst() {
        let reader = reader([
            containerStore: .success(Data("container".utf8)),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .loaded(url: containerStore, data: Data("container".utf8)))
    }

    /// Falls back to the legacy store only when the container store is missing.
    @Test func fallsBackToTheLegacyStoreOnlyWhenTheContainerStoreIsMissing() {
        let reader = reader([legacyStore: .success(Data("legacy".utf8))])

        #expect(reader.load(for: defaultProfile) == .loaded(url: legacyStore, data: Data("legacy".utf8)))
    }

    /// Reports an access denial instead of falling back to the legacy store.
    @Test func reportsAnAccessDenialInsteadOfFallingBackToTheLegacyStore() {
        let reader = reader([
            containerStore: .failure(Self.denied),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .accessDenied(url: containerStore, cause: .privacyProtected))
    }

    /// Reports a file-permissions denial with its cause.
    @Test func reportsAFilePermissionDenialWithItsCause() {
        let fileModeDenial = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]
        )
        let reader = reader([
            containerStore: .failure(fileModeDenial),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .accessDenied(url: containerStore, cause: .filePermissions))
    }

    /// Reports a denial with no POSIX cause as unspecified.
    @Test func reportsADenialWithNoPOSIXCauseAsUnspecified() {
        let bareDenial = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)
        let reader = reader([containerStore: .failure(bareDenial)])

        #expect(reader.load(for: defaultProfile) == .accessDenied(url: containerStore, cause: .unspecified))
    }

    /// Reports any other read failure instead of falling back.
    @Test func reportsAnyOtherReadFailureInsteadOfFallingBack() {
        let reader = reader([
            containerStore: .failure(Self.damaged),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .unreadable(url: containerStore))
    }

    /// Reports the store as missing when no candidate store exists.
    @Test func reportsMissingWhenNoCandidateStoreExists() {
        #expect(reader([:]).load(for: defaultProfile) == .missing)
    }

    /// A named profile reads the store in its own directory.
    @Test func aNamedProfileReadsTheStoreInItsOwnDirectory() {
        let profileRoot = URL(fileURLWithPath: "/Users/tester/Library/Safari/Profiles/Work", isDirectory: true)
        let profile = InstalledBrowserProfile(displayName: "Work", rootURL: profileRoot, isDefault: false)
        let store = profileRoot.appendingPathComponent("Cookies.binarycookies")
        let reader = reader([
            store: .success(Data("work".utf8)),
            containerStore: .success(Data("container".utf8)),
        ])

        #expect(reader.candidateURLs(for: profile) == [store])
        #expect(reader.load(for: profile) == .loaded(url: store, data: Data("work".utf8)))
    }

    /// Reads real files through the default data reader.
    @Test func readsRealFilesThroughTheDefaultDataReader() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-safari-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cook".utf8).write(to: legacy)

        let result = SafariCookieStoreReader(homeDirectory: home).load(for: defaultProfile)

        #expect(result == .loaded(url: legacy, data: Data("cook".utf8)))
    }

    /// The bytes of a store with one page per entry of `pageSizes`: the `cook`
    /// header, the big-endian page table, then each page filled with `0xAB`.
    /// The reader only follows the page table, so page contents do not matter.
    private static func storeBytes(pageSizes: [Int]) -> Data {
        var bytes = Array("cook".utf8) + bigEndian(UInt32(pageSizes.count))
        for size in pageSizes {
            bytes += bigEndian(UInt32(size))
        }
        for size in pageSizes {
            bytes += [UInt8](repeating: 0xAB, count: size)
        }
        return Data(bytes)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Writes `contents` as a named profile's store under a new temporary home
    /// and returns the home, the profile and the store's URL.
    private func temporaryStore(_ contents: Data) throws -> (home: URL, profile: InstalledBrowserProfile, store: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-safari-reader-\(UUID().uuidString)", isDirectory: true)
        let root = home.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("Cookies.binarycookies")
        try contents.write(to: store)
        return (home, InstalledBrowserProfile(displayName: "Work", rootURL: root, isDefault: false), store)
    }

    /// The default reader stops at the end of the last page, so Safari's trailer is never loaded.
    @Test func theDefaultReaderStopsAtTheEndOfTheLastPage() throws {
        let pages = Self.storeBytes(pageSizes: [16, 32])
        let fixture = try temporaryStore(pages + Data(repeating: 0xEE, count: 4_096))
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home).load(for: fixture.profile)

        #expect(result == .loaded(url: fixture.store, data: pages))
    }

    /// A trailer larger than the read limit does not make the store too large: only the pages count.
    @Test func aTrailerLargerThanTheLimitDoesNotRejectTheStore() throws {
        let pages = Self.storeBytes(pageSizes: [16])
        let fixture = try temporaryStore(pages + Data(repeating: 0xEE, count: 1_000))
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home, maximumStoreBytes: 64)
            .load(for: fixture.profile)

        #expect(result == .loaded(url: fixture.store, data: pages))
    }

    /// A store that exactly fills the read limit is read whole.
    @Test func aStoreThatExactlyFillsTheLimitIsRead() throws {
        let pages = Self.storeBytes(pageSizes: [52])
        let fixture = try temporaryStore(pages)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home, maximumStoreBytes: pages.count)
            .load(for: fixture.profile)

        #expect(result == .loaded(url: fixture.store, data: pages))
    }

    /// Pages that run past the read limit are reported as too large instead of being loaded.
    @Test func pagesPastTheLimitAreReportedAsTooLarge() throws {
        let fixture = try temporaryStore(Self.storeBytes(pageSizes: [53]))
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home, maximumStoreBytes: 64)
            .load(for: fixture.profile)

        #expect(result == .tooLarge(url: fixture.store))
    }

    /// A page table that runs past the read limit is reported as too large.
    @Test func aPageTablePastTheLimitIsReportedAsTooLarge() throws {
        let fixture = try temporaryStore(Self.storeBytes(pageSizes: [Int](repeating: 0, count: 100)))
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home, maximumStoreBytes: 64)
            .load(for: fixture.profile)

        #expect(result == .tooLarge(url: fixture.store))
    }

    /// A small file whose header claims far more pages than it holds is handed
    /// to the parser as it is, so it is reported as damaged rather than too large.
    @Test func aHeaderThatOverstatesTheFileIsLeftToTheParser() throws {
        let overstated = Data(Array("cook".utf8) + Self.bigEndian(UInt32.max) + [0, 0, 0, 1])
        let fixture = try temporaryStore(overstated)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home, maximumStoreBytes: 64)
            .load(for: fixture.profile)

        #expect(result == .loaded(url: fixture.store, data: overstated))
        #expect(throws: SafariBinaryCookiesParser.ParseError.self) {
            try SafariBinaryCookiesParser().parse(overstated)
        }
    }

    /// A file that is not a cookie store is read no further than its header.
    @Test func aFileWithoutTheMagicNumberIsReadNoFurtherThanItsHeader() throws {
        let fixture = try temporaryStore(Data(repeating: 0x41, count: 10_000))
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let result = SafariCookieStoreReader(homeDirectory: fixture.home).load(for: fixture.profile)

        #expect(result == .loaded(url: fixture.store, data: Data(repeating: 0x41, count: 8)))
    }

    /// The default reader still reports a missing store as missing.
    @Test func theDefaultReaderReportsAMissingStore() throws {
        let fixture = try temporaryStore(Data())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try FileManager.default.removeItem(at: fixture.store)

        #expect(SafariCookieStoreReader(homeDirectory: fixture.home).load(for: fixture.profile) == .missing)
    }

    /// The default reader reports a store the file mode denies as a file-permission denial.
    /// Skipped as root, which reads a file whatever its mode says.
    @Test(.enabled(if: getuid() != 0))
    func theDefaultReaderReportsAFileModeDenial() throws {
        let fixture = try temporaryStore(Self.storeBytes(pageSizes: [16]))
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.store.path)

        let result = SafariCookieStoreReader(homeDirectory: fixture.home).load(for: fixture.profile)

        #expect(result == .accessDenied(url: fixture.store, cause: .filePermissions))
    }

    /// An injected reader can report a store as too large.
    @Test func anInjectedReaderCanReportAStoreAsTooLarge() {
        let reader = SafariCookieStoreReader(homeDirectory: home) { _ in
            throw SafariCookieStoreReader.StoreTooLarge()
        }

        #expect(reader.load(for: defaultProfile) == .tooLarge(url: containerStore))
    }

    /// Displays paths inside home with a tilde.
    @Test func displaysPathsInsideHomeWithATilde() {
        let reader = reader([:])

        #expect(reader.displayPath(for: containerStore)
            == "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        #expect(reader.displayPath(for: URL(fileURLWithPath: "/Volumes/Backup/Cookies.binarycookies"))
            == "/Volumes/Backup/Cookies.binarycookies")
    }

    /// Each read error maps to the store state the reader reports for it.
    @Test(arguments: [
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                        underlyingDomain: nil, underlyingCode: nil, expected: .permissionDenied(.unspecified)),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                        underlyingDomain: NSPOSIXErrorDomain, underlyingCode: Int(EPERM),
                        expected: .permissionDenied(.privacyProtected)),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                        underlyingDomain: NSPOSIXErrorDomain, underlyingCode: Int(EACCES),
                        expected: .permissionDenied(.filePermissions)),
        ReadFailureCase(domain: NSPOSIXErrorDomain, code: Int(EPERM),
                        underlyingDomain: nil, underlyingCode: nil, expected: .permissionDenied(.privacyProtected)),
        ReadFailureCase(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                        underlyingDomain: nil, underlyingCode: nil, expected: .permissionDenied(.filePermissions)),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                        underlyingDomain: NSPOSIXErrorDomain, underlyingCode: Int(EACCES),
                        expected: .permissionDenied(.filePermissions)),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue,
                        underlyingDomain: nil, underlyingCode: nil, expected: .missing),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue,
                        underlyingDomain: nil, underlyingCode: nil, expected: .missing),
        ReadFailureCase(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                        underlyingDomain: nil, underlyingCode: nil, expected: .missing),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                        underlyingDomain: NSPOSIXErrorDomain, underlyingCode: Int(ENOENT), expected: .missing),
        ReadFailureCase(domain: NSCocoaErrorDomain, code: CocoaError.fileReadCorruptFile.rawValue,
                        underlyingDomain: nil, underlyingCode: nil, expected: .other),
    ])
    func classifiesReadFailures(_ failure: ReadFailureCase) {
        #expect(SafariCookieStoreErrorKind(classifying: failure.error) == failure.expected)
    }
}
