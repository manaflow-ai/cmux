public import Foundation
public import QuartzCore

/// The check "one intent, one top-level animation" (plans/cmux-next/motion-inspector.md; binding rule 1 of the
/// motion cascade rules, Lawrence 2026-10-28: "cmd w on last tab in workspace ... should just be same as cmd shift
/// w animation, not animate closing the tab first, then the workspace"). One action (a key, a menu pick, a socket or
/// CLI call) animates only the outermost container that changes: the animations it starts in one turn are one
/// top-level animation; an animation of the same action that starts a frame or more later (after a daemon reply, a
/// repair pass) is a second, chained one, and fails the check.
///
/// The composition root tells the inspector each outermost action as it starts (``noteActionStarted(_:inputTimestamp:)``,
/// from the registry's will-run observers) and how to read the input the code running now answers
/// (``currentInput``: the run scope's input timestamp, which tasks a handler starts inherit). A record joins the
/// action whose input it answers; with no input to match (a CLI run, work after a reply outside the run's tasks),
/// the newest action started less than ``intentWindow`` before it.
extension MotionInspector {
    /// One action the inspector saw start.
    public struct Intent: Sendable, Equatable, Identifiable {
        public let id: UInt64
        /// The canonical action id (`closeTab`, `workspace.close`, ...).
        public let action: String
        /// The person's input the run answers (`NSEvent.timestamp`), nil for a run no person started.
        public let inputTimestamp: Double?
        /// Media time it started.
        public let wallStart: CFTimeInterval
    }

    /// One top-level animation of an intent: the records that started within one display frame of its first.
    public struct TopLevel: Sendable, Equatable {
        /// The first record of the group.
        public var first: MotionInspectorRecord
        /// Records in the group (children of the same turn included).
        public var records: Int
        /// Milliseconds of wall time after the intent started.
        public var afterIntentMs: Double
    }

    /// An intent with more than one top-level animation.
    public struct IntentViolation: Sendable, Equatable {
        public var intent: Intent
        public var topLevels: [TopLevel]
        /// How the records were tied to the intent: by the run's input (exact) or by the time window.
        public var matchedBy: String
    }

    /// How long after an action a record with no input to match is still taken as that action's (the 2 s user-intent
    /// window EmptyWorkspaceRepair also uses for a cascade's workspace close).
    public static let intentWindow: CFTimeInterval = 2

    /// An outermost action starts (the registry's will-run observer, while the inspector inspects).
    public func noteActionStarted(_ action: String, inputTimestamp: Double?) {
        guard isInspecting else { return }
        nextIntentID &+= 1
        intents.append(Intent(id: nextIntentID, action: action, inputTimestamp: inputTimestamp, wallStart: now()))
        if intents.count > Self.intentsKept { intents.removeFirst(intents.count - Self.intentsKept) }
    }

    /// Intents kept for the check.
    public static let intentsKept = 200

    /// The intent a record starting now belongs to, and how it was matched.
    func intentForNewRecord() -> (id: UInt64, exact: Bool)? {
        if let input = currentInput?(), let intent = intents.last(where: { $0.inputTimestamp == input }) {
            return (intent.id, true)
        }
        let wall = now()
        guard let intent = intents.last, wall - intent.wallStart < Self.intentWindow else { return nil }
        return (intent.id, false)
    }

    /// Every intent with more than one top-level animation. Loops (spinners, pulses) are indicators, not structure:
    /// they are left out.
    public func intentViolations() -> [IntentViolation] {
        let frame = frameInterval
        var out: [IntentViolation] = []
        for intent in intents {
            let mine = records.filter { $0.intent == intent.id && Self.isStructural($0) }.sorted { $0.wallStart < $1.wallStart }
            guard mine.count > 1 else { continue }
            var groups: [TopLevel] = []
            var groupStart = -CFTimeInterval.infinity
            for record in mine {
                if record.wallStart - groupStart > frame * 1.5 {
                    groupStart = record.wallStart
                    groups.append(TopLevel(first: record, records: 1, afterIntentMs: (record.wallStart - intent.wallStart) * 1000))
                } else {
                    groups[groups.count - 1].records += 1
                }
            }
            guard groups.count > 1 else { continue }
            out.append(IntentViolation(intent: intent, topLevels: groups,
                                       matchedBy: mine.allSatisfy(\.intentExact) ? "input" : "window"))
        }
        return out
    }

    static func isStructural(_ record: MotionInspectorRecord) -> Bool {
        if case .loop = record.curve { return false }
        return true
    }

    /// The `debug.motion` `intents` answer: every intent seen and the violations.
    func intentsReport() -> [String: Any] {
        let violations = intentViolations()
        return [
            "intents": intents.suffix(50).map { intent -> [String: Any] in
                ["id": intent.id, "action": intent.action, "records": records.filter { $0.intent == intent.id }.count]
            },
            "violations": violations.map { violation -> [String: Any] in
                ["action": violation.intent.action, "intent": violation.intent.id, "matched_by": violation.matchedBy,
                 "top_level": violation.topLevels.map { top -> [String: Any] in
                     ["owner": top.first.owner, "kind": top.first.kind, "property": top.first.property,
                      "start_ms": Self.ms(top.first.start * 1000), "after_intent_ms": Self.ms(top.afterIntentMs), "records": top.records]
                 }]
            },
            "passed": violations.isEmpty,
        ]
    }
}
