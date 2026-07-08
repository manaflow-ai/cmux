#if canImport(AppKit)
#if DEBUG

import AppKit
import Foundation
import Testing
@testable import CmuxAppKitSupportUI

/// Verifies the coercion helpers match the legacy `UserDefaults` reading shape and
/// that `copyCombinedToPasteboard` writes the injected payload onto the injected
/// pasteboard. Each test uses a scoped `UserDefaults(suiteName:)` and a uniquely
/// named `NSPasteboard` so the shared environment is never touched.
@MainActor
@Suite struct DebugWindowConfigSnapshotServiceTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "DebugWindowConfigSnapshotServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("DebugWindowConfigSnapshotServiceTests.\(UUID().uuidString)"))
    }

    @Test func stringValueReturnsStoredValueThenFallback() {
        let defaults = makeDefaults()
        defaults.set("stored", forKey: "k")
        let service = DebugWindowConfigSnapshotService(defaults: defaults) { _ in "" }
        #expect(service.stringValue(key: "k", fallback: "fb") == "stored")
        #expect(service.stringValue(key: "missing", fallback: "fb") == "fb")
    }

    @Test func doubleValueAcceptsNumberStringAndFallback() {
        let defaults = makeDefaults()
        defaults.set(1.5, forKey: "num")
        defaults.set("2.25", forKey: "str")
        let service = DebugWindowConfigSnapshotService(defaults: defaults) { _ in "" }
        #expect(service.doubleValue(key: "num", fallback: 0) == 1.5)
        #expect(service.doubleValue(key: "str", fallback: 0) == 2.25)
        #expect(service.doubleValue(key: "missing", fallback: 9.0) == 9.0)
    }

    @Test func boolValueReturnsFallbackOnlyWhenAbsent() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "explicitFalse")
        let service = DebugWindowConfigSnapshotService(defaults: defaults) { _ in "" }
        // Present-but-false must NOT fall through to the fallback.
        #expect(service.boolValue(key: "explicitFalse", fallback: true) == false)
        #expect(service.boolValue(key: "missing", fallback: true) == true)
    }

    @Test func copyCombinedToPasteboardWritesInjectedPayload() {
        let pasteboard = makePasteboard()
        let service = DebugWindowConfigSnapshotService(
            defaults: makeDefaults(),
            pasteboard: pasteboard
        ) { _ in "the-combined-payload" }
        service.copyCombinedToPasteboard()
        #expect(pasteboard.string(forType: .string) == "the-combined-payload")
    }
}

#endif
#endif
