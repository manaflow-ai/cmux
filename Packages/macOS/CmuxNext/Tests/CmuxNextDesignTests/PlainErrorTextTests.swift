@testable import CmuxNextDesign
import Foundation
import Testing

/// A system error reads in plain words, and any other error as one plain generic line: never its
/// `localizedDescription` or `String(describing:)` (Leo, 2026-11-12: "we want good error states. We don't want busted
/// errors.").
struct PlainErrorTextTests {
    private struct Opaque: Error {}

    /// What a person must never read: Cocoa's "Error Domain=… Code=…" dump.
    static func isRaw(_ text: String) -> Bool {
        text.contains("Error Domain=") || text.contains("Code=") || text.contains("NSURLError") || text.contains("NSPOSIX")
    }

    @Test func noConnectionReadsAsOffline() {
        #expect(PlainErrorText.text(URLError(.notConnectedToInternet)) == PlainErrorText.words(.offline))
        #expect(PlainErrorText.text(URLError(.networkConnectionLost)) == PlainErrorText.words(.offline))
        #expect(PlainErrorText.words(.offline) == "You're offline. Check your network, then try again.")
    }

    @Test(arguments: [
        (URLError.Code.timedOut, PlainErrorText.Kind.timedOut),
        (.cannotConnectToHost, .unreachable),
        (.cannotFindHost, .unreachable),
        (.dnsLookupFailed, .unreachable),
        (.secureConnectionFailed, .secureConnection),
    ])
    func networkErrorsHaveWords(code: URLError.Code, kind: PlainErrorText.Kind) {
        #expect(PlainErrorText.kind(of: URLError(code)) == kind)
    }

    @Test func fileSystemErrorsHaveWords() {
        #expect(PlainErrorText.kind(of: POSIXError(.ENOSPC)) == .noSpace)
        #expect(PlainErrorText.kind(of: POSIXError(.EACCES)) == .permission)
        #expect(PlainErrorText.kind(of: POSIXError(.EROFS)) == .readOnly)
        #expect(PlainErrorText.kind(of: CocoaError(.fileWriteOutOfSpace)) == .noSpace)
        #expect(PlainErrorText.kind(of: CocoaError(.fileWriteVolumeReadOnly)) == .readOnly)
        #expect(PlainErrorText.kind(of: CocoaError(.fileNoSuchFile)) == .notFound)
        #expect(PlainErrorText.kind(of: NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))) == .exists)
    }

    /// A Cocoa error that wraps a POSIX one ("couldn't be saved" over ENOSPC) reads as the POSIX one.
    @Test func aWrappedErrorReadsAsTheOneItWraps() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(PlainErrorText.kind(of: wrapped) == .noSpace)
    }

    @Test func anUnknownErrorReadsAsTheGenericLine() {
        #expect(PlainErrorText.words(Opaque()) == nil)
        #expect(PlainErrorText.text(Opaque()) == PlainErrorText.generic)
        #expect(PlainErrorText.text(NSError(domain: "SUSparkleErrorDomain", code: 1001)) == PlainErrorText.generic)
        #expect(PlainErrorText.generic == "Something went wrong. Try again.")
    }

    @Test func noTextIsRaw() {
        let errors: [any Error] = [URLError(.notConnectedToInternet), URLError(.badServerResponse), POSIXError(.EIO),
                                   CocoaError(.fileWriteUnknown), NSError(domain: "x", code: -1), Opaque()]
        for error in errors {
            let text = PlainErrorText.text(error)
            #expect(!Self.isRaw(text), "\(text)")
            #expect(text != error.localizedDescription, "\(error) shows its localizedDescription")
        }
    }
}
