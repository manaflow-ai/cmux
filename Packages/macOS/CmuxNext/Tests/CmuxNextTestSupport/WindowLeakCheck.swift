public import AppKit
public import Testing
import Darwin
import ObjectiveC

/// A suite that opens windows closes them: `@Suite(.closesItsWindows)` on the top-level suite type.
///
/// Every window a test opens stays in the one test process until something closes it, and every
/// Core Animation commit lays out each open window that needs it. The broad Swift pass went from
/// 3 to 428 windows (2026-10-28) and slowed from about 2,000 tests a minute to about 100, so later
/// suites timed out for windows earlier ones left. When the suite ends, this trait closes every
/// window its tests created that is still open, names them on stderr, and records an issue on the
/// suite, so the suite that leaks fails by name instead of slowing every suite after it.
///
/// Windows are tagged with the suite and test that created them when they are created
/// (Tests/Support/CmuxNextTestExitTrace/CmuxNextTestWindowCensus.c), so a suite running in
/// parallel with others closes only its own. A window its test closed is not a leak, even when
/// something still holds it; a window that was never closed is, whether or not it is on screen.
public struct WindowLeakCheck: SuiteTrait, TestScoping {
    public var isRecursive: Bool { false }

    @concurrent public nonisolated func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        var thrown: (any Error)?
        do {
            try await function()
        } catch {
            thrown = error
        }
        guard testCase == nil, test.isSuite else {
            if let thrown { throw thrown }
            return
        }
        guard test.id.nameComponents.count == 1 else {
            // Windows are grouped by the top-level suite, so a nested suite's check would close
            // windows its sibling suites still use.
            Issue.record("closesItsWindows belongs on the top-level suite type, not \(test.name)", sourceLocation: test.sourceLocation)
            if let thrown { throw thrown }
            return
        }
        let suite = WindowLeaks.suiteKey(of: test.id)
        let leaked = await WindowLeaks.closeLeaks(ofSuite: suite)
        if !leaked.isEmpty {
            let message = WindowLeaks.leakMessage(suite: suite, leaked: leaked)
            let line = Array(("cmux-next window leak: " + message + "\n").utf8)
            _ = line.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
            Issue.record(Comment(rawValue: message), sourceLocation: test.sourceLocation)
        }
        if let thrown { throw thrown }
    }
}

extension Trait where Self == WindowLeakCheck {
    /// Closes, names and fails on the windows a suite's tests left open (``WindowLeakCheck``).
    public static var closesItsWindows: Self { WindowLeakCheck() }
}

/// What the window census knows about a window (CmuxNextTestWindowCensus.c).
public enum WindowLeaks {
    /// One window a suite left open, as the leak report names it.
    public struct Leak: Sendable, Equatable {
        public var className: String
        public var title: String
        public var test: String
        public var wasOnScreen: Bool
    }

    /// The key windows are grouped by: the module and the top-level suite type.
    public nonisolated static func suiteKey(of id: Test.ID) -> String {
        id.moduleName + "." + (id.nameComponents.first ?? "")
    }

    /// 1 when the census tags windows in this process (the test bundle links it).
    public static var isInstalled: Bool {
        NSWindow.instancesRespond(to: ownerSelector)
    }

    /// "Module.Suite" and the test that created `window`, or nil for a window created outside a test.
    public static func owner(of window: NSWindow) -> (suite: String, test: String)? {
        guard window.responds(to: ownerSelector),
              let value = window.perform(ownerSelector)?.takeUnretainedValue() as? String
        else { return nil }
        let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    /// Whether `window` was closed and not ordered back in since.
    public static func wasClosed(_ window: NSWindow) -> Bool {
        guard window.responds(to: closedSelector) else { return false }
        typealias Read = @convention(c) (NSWindow, Selector) -> Bool
        let read = unsafeBitCast(window.method(for: closedSelector), to: Read.self)
        return read(window, closedSelector)
    }

    /// The windows `suite`'s tests created that are still open. AppKit's own windows are left
    /// out: the text input window (TUINSWindow) and the spelling window (SPRoundedWindow) are
    /// made by AppKit while a test's field has focus, and AppKit keeps and reuses them.
    public static func openWindows(ofSuite suite: String) -> [NSWindow] {
        NSApp?.windows.filter { owner(of: $0)?.suite == suite && !wasClosed($0) && !isAppKitsOwn($0) } ?? []
    }

    /// A window of a private AppKit class (not NSWindow or NSPanel themselves), which no test opens.
    public static func isAppKitsOwn(_ window: NSWindow) -> Bool {
        var windowClass: AnyClass = type(of: window)
        // KVO's dynamic subclass stands in for the real class.
        while NSStringFromClass(windowClass).hasPrefix("NSKVONotifying_"), let superclass = class_getSuperclass(windowClass) {
            windowClass = superclass
        }
        if windowClass == NSWindow.self || windowClass == NSPanel.self { return false }
        guard let image = class_getImageName(windowClass) else { return false }
        return String(cString: image).hasPrefix("/System/")
    }

    /// Closes the windows `suite` left open and returns what they were. A window released without
    /// a close leaves the list when its autorelease pool drains, so one main-actor turn passes
    /// before a window counts as left open.
    public static func closeLeaks(ofSuite suite: String) async -> [Leak] {
        guard !openWindows(ofSuite: suite).isEmpty else { return [] }
        try? await Task.sleep(for: .milliseconds(50))
        return openWindows(ofSuite: suite).map { window in
            let leak = Leak(
                className: String(describing: type(of: window)),
                title: window.title,
                test: owner(of: window)?.test ?? "",
                wasOnScreen: window.isVisible
            )
            window.isReleasedWhenClosed = false
            window.close()
            return leak
        }
    }

    public nonisolated static func leakMessage(suite: String, leaked: [Leak]) -> String {
        let onScreen = leaked.filter(\.wasOnScreen).count
        let listed = leaked.prefix(8).map { leak in
            "\(leak.className) \"\(leak.title)\" from \(leak.test.isEmpty ? "the suite" : leak.test)"
        }
        return "\(suite) left \(leaked.count) window\(leaked.count == 1 ? "" : "s") open (\(onScreen) on screen): "
            + listed.joined(separator: ", ") + (leaked.count > 8 ? ", ..." : "")
            + ". Close each window a test opens in that test's own teardown (defer or addTeardownBlock); this check closed them."
    }

    private static let ownerSelector = NSSelectorFromString("cmuxNextTestOwner")
    private static let closedSelector = NSSelectorFromString("cmuxNextTestWasClosed")
}

/// The census's question at each window's init: which suite and test is running? A C string
/// ("Module.Suite\ttest()") the caller frees, or nil outside a test.
@_cdecl("cmux_next_test_window_owner")
public nonisolated func cmuxNextTestWindowOwner() -> UnsafeMutablePointer<CChar>? {
    guard let test = Test.current else { return nil }
    let suite = WindowLeaks.suiteKey(of: test.id)
    let name = test.isSuite ? "" : test.id.nameComponents.dropFirst().joined(separator: ".")
    return strdup(suite + "\t" + name)
}
