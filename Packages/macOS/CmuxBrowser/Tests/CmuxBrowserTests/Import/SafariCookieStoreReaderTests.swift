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

    @Test func readsTheContainerStoreFirst() {
        let reader = reader([
            containerStore: .success(Data("container".utf8)),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .loaded(url: containerStore, data: Data("container".utf8)))
    }

    @Test func fallsBackToTheLegacyStoreOnlyWhenTheContainerStoreIsMissing() {
        let reader = reader([legacyStore: .success(Data("legacy".utf8))])

        #expect(reader.load(for: defaultProfile) == .loaded(url: legacyStore, data: Data("legacy".utf8)))
    }

    @Test func reportsAnAccessDenialInsteadOfFallingBackToTheLegacyStore() {
        let reader = reader([
            containerStore: .failure(Self.denied),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .accessDenied(url: containerStore, cause: .privacyProtected))
    }

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

    @Test func reportsADenialWithNoPOSIXCauseAsUnspecified() {
        let bareDenial = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)
        let reader = reader([containerStore: .failure(bareDenial)])

        #expect(reader.load(for: defaultProfile) == .accessDenied(url: containerStore, cause: .unspecified))
    }

    @Test func reportsAnyOtherReadFailureInsteadOfFallingBack() {
        let reader = reader([
            containerStore: .failure(Self.damaged),
            legacyStore: .success(Data("legacy".utf8)),
        ])

        #expect(reader.load(for: defaultProfile) == .unreadable(url: containerStore))
    }

    @Test func reportsMissingWhenNoCandidateStoreExists() {
        #expect(reader([:]).load(for: defaultProfile) == .missing)
    }

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

    @Test func displaysPathsInsideHomeWithATilde() {
        let reader = reader([:])

        #expect(reader.displayPath(for: containerStore)
            == "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        #expect(reader.displayPath(for: URL(fileURLWithPath: "/Volumes/Backup/Cookies.binarycookies"))
            == "/Volumes/Backup/Cookies.binarycookies")
    }

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
