import AppKit

/// Reports subview removals from the main window's root view while AppKit is
/// hit-testing it.
///
/// `-[NSView hitTest:]` reads its subview count once and then walks the array
/// by index from the top. A removal made while that walk is in flight shifts
/// the array under it, and AppKit throws `NSRangeException` once the walk
/// reaches an index past the new end (CMUXTERM-MACOS-41RH: index 141 against
/// 133 subviews, during cursor-update routing). The walk calls each child's
/// `hitTest(_:)`, so the code that removes subviews is still on the stack
/// when `willRemoveSubview(_:)` runs. The first such removal per process is
/// captured with that stack, which names the re-entrant path even when the
/// removal does not shrink the array far enough to crash.
@MainActor
final class MainWindowHitTestMutationMonitor {
    struct Mutation: Equatable {
        let removedSubviewType: String
        let subviewCountBeforeRemoval: Int
        let eventType: UInt?
    }

    /// One report per process across all main windows; tests inject a
    /// reporter, which gets its own flag.
    private static var hasReportedToSentry = false

    private var walkDepth = 0
    private var hasReported = false
    private let report: @MainActor (Mutation) -> Void

    var isWalking: Bool { walkDepth > 0 }

    init(report: @escaping @MainActor (Mutation) -> Void = MainWindowHitTestMutationMonitor.reportToSentry) {
        self.report = report
    }

    /// Runs one hit-test walk of the root view, nesting safely.
    func walk<Result>(_ body: () -> Result) -> Result {
        walkDepth += 1
        defer { walkDepth -= 1 }
        return body()
    }

    func subviewWillBeRemoved(_ subview: NSView, subviewCount: Int, eventType: NSEvent.EventType?) {
        guard walkDepth > 0, !hasReported else { return }
        hasReported = true
        report(Mutation(
            removedSubviewType: String(describing: type(of: subview)),
            subviewCountBeforeRemoval: subviewCount,
            eventType: eventType?.rawValue
        ))
    }

    private static func reportToSentry(_ mutation: Mutation) {
        guard !hasReportedToSentry else { return }
        hasReportedToSentry = true
        let data: [String: Any] = [
            "removedSubviewType": mutation.removedSubviewType,
            "subviewCountBeforeRemoval": mutation.subviewCountBeforeRemoval,
            "eventType": mutation.eventType.map { Int($0) } ?? -1,
        ]
#if DEBUG
        cmuxDebugLog(
            "mainWindow.hitTestMutation removed=\(mutation.removedSubviewType) " +
            "count=\(mutation.subviewCountBeforeRemoval) event=\(mutation.eventType.map(String.init) ?? "nil")"
        )
#endif
        sentryCaptureWarning(
            "Main window root view lost a subview during hit testing",
            category: "mainWindow.hitTestMutation",
            data: data
        )
    }
}
