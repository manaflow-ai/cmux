import Foundation

/// An Objective-C exception that a macOS framework throws in its own code, that AppKit catches and
/// logs in every other app, and that cmux survives instead of crashing on
/// (`NSApplicationCrashOnExceptions`), in ``CrashReporter/reportException(_:crashes:record:report:)``.
///
/// A rule matches only when the throw and the frame that called it are both system code named in
/// the rule, so no cmux frame sits between the throw and AppKit's catch (the 2026-10-07 case, where
/// an unwind through Swift left the executor corrupt, cannot match). Everything else still crashes.
nonisolated struct SurvivableSystemException: Equatable, Sendable {
    /// One known framework bug: the exception's name, the start of its reason, the method that
    /// throws and the system method that called it.
    struct Rule: Equatable, Sendable {
        var id: String
        var name: String
        var reasonPrefix: String
        var thrower: String
        var caller: String
    }

    /// The known framework bugs cmux survives.
    static let rules: [Rule] = [
        // #33743: a drag in the Quick Look panel's preview runs its pan gesture's action with a
        // mouse-drag as NSApp.currentEvent; QuickLookUI asks that event for its touches, and AppKit
        // throws, since only gesture events have touches. AppKit's catch is in
        // _NSGestureRecognizerSendOneAction, two system frames up: the drag does not start, as in
        // Finder and every app that does not crash on exceptions.
        Rule(id: "quicklook-panel-drag-touches", name: "NSInternalInconsistencyException",
             reasonPrefix: "Invalid message sent to event", thrower: "-[NSEvent touchesMatchingPhase:inView:]",
             caller: "-[QLPanelPreviewView startDragFromGesture:"),
    ]

    var name: String
    var reason: String
    /// `callStackSymbols`, the throw site first: "4  AppKit  0x… -[NSEvent touchesMatchingPhase:inView:] + 428".
    var frames: [String]

    init(name: String, reason: String, frames: [String]) {
        self.name = name
        self.reason = reason
        self.frames = frames
    }

    /// The rule this exception matches, or nil: then it is fatal.
    var rule: Rule? {
        Self.rules.first { rule in
            guard name == rule.name, reason.hasPrefix(rule.reasonPrefix),
                  let throwSite = frames.firstIndex(where: { $0.contains(rule.thrower) }),
                  frames.index(after: throwSite) < frames.endIndex else { return false }
            return frames[frames.index(after: throwSite)].contains(rule.caller)
        }
    }
}
