import CmuxNextDesign
@testable import CmuxNextUpdater
import Foundation
import Testing

/// An update failure reads in plain words at every site (the sheet, Settings, the probe, a channel
/// switch, a rollback): never Sparkle's or Cocoa's own text (Leo, 2026-11-12: "we want good error
/// states. We don't want busted errors.").
@Suite struct UpdateFailureTextTests {
    private struct Opaque: Error {}

    private static func sparkle(_ code: Int, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "An error occurred while downloading the update."]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: UpdateFailureText.sparkleDomain, code: code, userInfo: info)
    }

    @Test func noConnectionReadsAsOffline() {
        #expect(UpdateFailureText.plain(URLError(.notConnectedToInternet)) == PlainErrorText.words(.offline))
        // Sparkle's download error wraps the network error that stopped it.
        #expect(UpdateFailureText.plain(Self.sparkle(2001, underlying: URLError(.notConnectedToInternet) as NSError))
            == PlainErrorText.words(.offline))
    }

    @Test func aSparkleFailureReadsByItsStage() {
        #expect(UpdateFailureText.plain(Self.sparkle(1000)) == UpdateFailureText.sparkleStage(1000))
        #expect(UpdateFailureText.plain(Self.sparkle(2001)) == UpdateFailureText.sparkleStage(2001))
        #expect(UpdateFailureText.plain(Self.sparkle(3001)) == UpdateFailureText.sparkleStage(3001))
        #expect(UpdateFailureText.plain(Self.sparkle(4005)) == UpdateFailureText.sparkleStage(4005))
        #expect(Set([1000, 2001, 3001, 4005].compactMap(UpdateFailureText.sparkleStage)).count == 4)
    }

    @Test func anUnknownErrorReadsAsTheGenericLine() {
        #expect(UpdateFailureText.plain(Opaque()) == UpdateFailureText.generic)
        #expect(UpdateFailureText.plain(NSError(domain: "x", code: 7)) == UpdateFailureText.generic)
        #expect(UpdateFailureText.plain(Self.sparkle(9999)) == UpdateFailureText.generic)
    }

    @Test func noTextIsRaw() {
        let errors: [any Error] = [URLError(.badServerResponse), Self.sparkle(2001), Self.sparkle(9999), Opaque(),
                                   CocoaError(.fileWriteUnknown), NSError(domain: NSOSStatusErrorDomain, code: -67_062)]
        for error in errors {
            let text = UpdateFailureText.plain(error)
            #expect(!text.contains("Error Domain=") && !text.contains("Code=") && !text.contains("Opaque"), "\(text)")
            #expect(text != error.localizedDescription, "\(error) shows its localizedDescription")
        }
        #expect(!UpdaterStrings.channelsSwitchFailed.contains("%@"))
    }
}
