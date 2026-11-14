public import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

extension PageDescriptor {
    /// A Cloud machine on its way to an open terminal (webviews/src/pages/cloud-progress):
    /// cmux-page://cmux.cloud-progress/. It fills a window's content area for a New Cloud Workspace
    /// and for a window on a paused machine's workspace, until the workspace is mirrored.
    public static let cloudProgress = PageDescriptor(
        id: "cmux.cloud-progress", resource: "cloud-progress", namespaces: ["cmux.cloudProgress."])
}

/// One Cloud creation as the progress page reads it: plain values, so the page's provider needs no
/// App type. The App's `CloudMachineCreation` is one (its stage, its machine's name, the time so far).
@MainActor
public protocol CloudProgressSource: AnyObject {
    /// `CloudMachineStage.name`.
    var progressStage: String { get }
    /// The stage's place in `progressSteps`; nil for a stage off the list (paused, a change, failed).
    var progressStepIndex: Int? { get }
    /// `CloudMachineStage.steps` by name, in order.
    var progressSteps: [String] { get }
    var progressFailure: String? { get }
    /// Paused by the idle auto-pause.
    var progressIdle: Bool { get }
    var progressMachine: String? { get }
    /// Ready, paused or failed: the page's elapsed line stops.
    var progressFinished: Bool { get }
    /// Time since the attempt started, or until it was ready.
    func progressElapsed() -> Duration
    /// Something the page shows may have changed: read inside an observation (stage, machine, workspace).
    var progressChangeKey: String { get }
}

/// A question the creation asks the person on its own page instead of a sheet: an agent's or a
/// script's create asks first, the backend holds the create for approval, or a plan refusal offers
/// the upgrade. The App has the words.
public struct CloudProgressAsk: Equatable, Sendable {
    public enum Kind: String, Sendable { case createRequest, approval, upgrade }
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    /// The yes button (Create, Upgrade).
    public var button: String
    /// The no button.
    public var cancel: String

    public init(id: String = UUID().uuidString, kind: Kind, title: String, body: String, button: String, cancel: String) {
        (self.id, self.kind, self.title, self.body, self.button, self.cancel) = (id, kind, title, body, button, cancel)
    }

    var json: JSONValue {
        .object(["id": .string(id), "kind": .string(kind.rawValue), "title": .string(title), "body": .string(body),
                 "button": .string(button), "cancel": .string(cancel)])
    }
}

/// Serves the progress page's `cmux.cloudProgress.` namespace from one ``CloudProgressSource``.
///
/// - `cmux.cloudProgress.state` → ``state()``: the stage by name, the step reached, the failure,
///   the machine's name and the time so far. The page has the words (its own catalog).
/// - stream `cmux.cloudProgress.changes`: one empty event per change of ``CloudProgressSource/progressChangeKey``,
///   from an observation (no timer). The page ticks its own elapsed line.
/// - `retry`, `dismiss`, `copyError`: the person's own click or key only.
/// - ``ask(_:done:)`` puts a question on the page (`state`'s `ask`); `cmux.cloudProgress.answer {id, accept}`,
///   the person's own click or key only, answers it. Dismiss, the page leaving its window and a newer
///   question each answer the open one no.
@MainActor
public final class CloudProgressPageProvider: PageProvider {
    public struct Actions {
        public var retry: @MainActor () -> Void
        public var dismiss: @MainActor () -> Void
        /// Copies the failure's text.
        public var copy: @MainActor (String) -> Void
        /// The refusal of an action the page asked for without the person's own click or key (the App's words).
        public var personOnlyMessage: String

        public init(retry: @escaping @MainActor () -> Void, dismiss: @escaping @MainActor () -> Void,
                    copy: @escaping @MainActor (String) -> Void, personOnlyMessage: String) {
            (self.retry, self.dismiss, self.copy, self.personOnlyMessage) = (retry, dismiss, copy, personOnlyMessage)
        }
    }

    public static let stateOp = "cmux.cloudProgress.state"
    public static let changesStream = "cmux.cloudProgress.changes"
    public static let retryOp = "cmux.cloudProgress.retry"
    public static let dismissOp = "cmux.cloudProgress.dismiss"
    public static let copyErrorOp = "cmux.cloudProgress.copyError"
    public static let answerOp = "cmux.cloudProgress.answer"

    public let source: any CloudProgressSource
    private let actions: Actions
    /// The step a failure or a pause stopped at: the last one reached before it.
    private var lastReached = 0
    /// The open question and who waits on its answer.
    private var openAsk: (ask: CloudProgressAsk, done: @MainActor (Bool) -> Void)?
    /// The pages' change streams, told when a question opens or closes (the source's key does not change then).
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

    /// The question the page shows now.
    public var shownAsk: CloudProgressAsk? { openAsk?.ask }

    public init(source: any CloudProgressSource, actions: Actions) {
        self.source = source
        self.actions = actions
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp:
            return state()
        case Self.retryOp, Self.dismissOp, Self.copyErrorOp, Self.answerOp:
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: actions.personOnlyMessage)
            }
            switch op {
            case Self.retryOp: actions.retry()
            case Self.dismissOp:
                answer(nil, accept: false)
                actions.dismiss()
            case Self.answerOp:
                guard let id = params["id"]?.stringValue, case .bool(let accept)? = params["accept"] else {
                    throw PageError.invalidParams("id and accept are required")
                }
                answer(id, accept: accept)
            default:
                if let failure = source.progressFailure { actions.copy(failure) }
            }
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let source = source
        let listener = UUID()
        listeners[listener] = onEvent
        // task-owner: lives as long as the page's subscription; event-driven (Observation)
        // main-hop-allow: a subscription's observation loop, not an action's work: each wake reads one key and
        // sends at most one empty event; it ends with the subscription (the page closes or the window moves on).
        let task = Task { @MainActor in
            var last: String?
            for await key in ObservationStream({ source.progressChangeKey }) {
                guard !Task.isCancelled else { return }
                if key == last { continue }
                // The first value is the state the page reads with `state`; only changes are events.
                if last != nil { onEvent(.object([:])) }
                last = key
            }
        }
        return PageSubscription { [weak self] in
            task.cancel()
            self?.listeners[listener] = nil
        }
    }

    /// What the page draws now. `step` is the stage's place in the list, or the last one reached
    /// while it fails, pauses or changes; `elapsedMs` stops at ready.
    public func state() -> JSONValue {
        let step = source.progressStepIndex ?? lastReached
        if source.progressFailure == nil { lastReached = step }
        let elapsed = source.progressElapsed().components
        let elapsedMs = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds / 1_000_000_000_000_000)
        return .object([
            "stage": .string(source.progressStage),
            "step": .number(Double(step)),
            "steps": .array(source.progressSteps.map(JSONValue.string)),
            "failure": source.progressFailure.map(JSONValue.string) ?? .null,
            "idle": .bool(source.progressIdle),
            "machine": source.progressMachine.map(JSONValue.string) ?? .null,
            "elapsedMs": .number(elapsedMs),
            "finished": .bool(source.progressFinished),
            "ask": openAsk?.ask.json ?? .null,
        ])
    }

    /// Shows `ask` on the page; `done` runs once with the person's answer (false for no, Dismiss, the
    /// page leaving its window, or a newer question).
    public func ask(_ ask: CloudProgressAsk, done: @escaping @MainActor (Bool) -> Void) {
        answer(nil, accept: false)
        openAsk = (ask, done)
        changed()
    }

    /// ``ask(_:done:)`` as a wait. A cancelled wait answers no and takes the question off the page.
    public func ask(_ ask: CloudProgressAsk) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.ask(ask) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            // main-hop-allow: a cancelled wait's one answer: it closes one question on the main actor and sends one event.
            Task { @MainActor [weak self] in self?.answer(ask.id, accept: false) }
        }
    }

    /// Answers the open question (`id` nil: whichever is open); nothing when another one is open.
    public func answer(_ id: String?, accept: Bool) {
        guard let open = openAsk, id == nil || open.ask.id == id else { return }
        openAsk = nil
        changed()
        open.done(accept)
    }

    private func changed() {
        for onEvent in listeners.values { onEvent(.object([:])) }
    }
}
