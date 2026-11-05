import Foundation
import Testing
@testable import CmuxMobileTransport

/// A security scope that counts its starts and stops (the system's needs a
/// real Files pick): `open` is how many accesses are open now.
final class RecordingScope: SecurityScope, @unchecked Sendable {
    /// What `startAccessing` answers: false is a URL with no scope (an app file).
    let grants: Bool
    private let lock = NSLock()
    private var started = 0
    private var stopped = 0

    init(grants: Bool = true) { self.grants = grants }

    var starts: Int { lock.withLock { started } }
    var stops: Int { lock.withLock { stopped } }
    var open: Int { lock.withLock { started - stopped } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { started += 1 }
        return grants
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stopped += 1 }
    }
}

/// A picked file keeps its URL, not a copy of its bytes; every reader opens
/// its security scope around each use and closes it, failures included.
@Suite struct ScopedFileTests {
    struct Boom: Error {}

    static let url = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/report.docx")

    @Test func withAccessOpensAroundTheReadAndClosesAfter() {
        let scope = RecordingScope()
        let file = ScopedFile(Self.url, scope: scope)

        let openDuring = file.withAccess { url -> Int in
            #expect(url == Self.url)
            return scope.open
        }

        #expect(openDuring == 1)
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    @Test func withAccessClosesWhenTheReadThrows() {
        let scope = RecordingScope()
        #expect(throws: Boom.self) {
            try ScopedFile(Self.url, scope: scope).withAccess { _ -> Void in throw Boom() }
        }
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    @Test func anOpenAccessClosesOnceWhetherClosedOrReleased() {
        let scope = RecordingScope()
        let access = ScopedFile(Self.url, scope: scope).open()
        #expect(access.url == Self.url)
        #expect(scope.open == 1)
        access.close()
        access.close()
        #expect(scope.stops == 1)

        do {
            let released = ScopedFile(Self.url, scope: scope).open()
            #expect(scope.open == 1)
            withExtendedLifetime(released) {}
        }
        #expect(scope.starts == 2)
        #expect(scope.stops == 2)
    }

    /// A URL with no scope (the app's own file, a picked video's copy): nothing to stop.
    @Test func aURLWithNoScopeIsNeverStopped() {
        let scope = RecordingScope(grants: false)
        ScopedFile(Self.url, scope: scope).open().close()
        #expect(scope.starts == 1)
        #expect(scope.stops == 0)
    }
}
