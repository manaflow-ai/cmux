public import CmuxNextDesign
public import CmuxNextSettings
public import Foundation

/// A question a Cloud start asks the person in its card, under their message (webviews
/// `CloudStartAsk.tsx`; leo-workspace design/cloud-start.md): its first harness login, the one-time
/// login copy consent, Codex's device code, Codex's Mac sign-in consent. The App words it from the
/// dialog spec it would otherwise show (``init(kind:spec:code:link:)``) and decides what an answer
/// does; the page only draws it and sends back the button the person clicked (`cloud.answerStart`).
/// Never a modal over the window: the start's own card holds it (Leo, 2026-11-06: "btw we ought to
/// have a lot of that ui in react and not swift / like me clicking cloud and starting a chat at all").
public nonisolated struct AgentPaneCloudAsk: Equatable, Sendable {
    /// What is asked; the page's look and its gallery variants key on it.
    public enum Kind: String, Sendable {
        case firstLogin, loginCopy, codexDevice, codexConsent
    }

    public struct Button: Equatable, Sendable {
        public var id: String
        public var title: String
        /// `default` (the one filled button), `cancel`, or `normal`.
        public var role: String

        public init(id: String, title: String, role: String) {
            (self.id, self.title, self.role) = (id, title, role)
        }
    }

    /// One ask of one start: a new id per ask, so a late click on an earlier ask answers nothing.
    public var id: String
    public var kind: Kind
    public var title: String
    public var lines: [String]
    public var buttons: [Button]
    /// A one-time code the page shows with Copy (Codex's device code).
    public var code: String?
    /// A page the person opens beside the buttons (Codex's sign-in page), never a second filled
    /// button: the card links to it, a dialog shows it as a button that opens it and asks again.
    public var link: URL?
    public var linkTitle: String?
    /// Its dialog's identifier where no card holds it (tests, automation, captures); never sent to the page.
    public var identifier: String?

    public init(id: String = UUID().uuidString, kind: Kind, title: String, lines: [String], buttons: [Button],
                code: String? = nil, link: URL? = nil, linkTitle: String? = nil, identifier: String? = nil) {
        (self.id, self.kind, self.title, self.lines, self.buttons) = (id, kind, title, lines, buttons)
        (self.code, self.link, self.linkTitle, self.identifier) = (code, link, linkTitle, identifier)
    }

    /// The ask a dialog spec would have shown: its title, lines, buttons (by id and role) and identifier.
    public init(kind: Kind, spec: CmuxDialogSpec, code: String? = nil, link: URL? = nil, linkTitle: String? = nil) {
        self.init(kind: kind, title: spec.title, lines: spec.lines,
                  buttons: spec.buttons.map { Button(id: $0.id, title: $0.title, role: $0.role == .default ? "default" : $0.role == .cancel ? "cancel" : "normal") },
                  code: code, link: link, linkTitle: linkTitle, identifier: spec.identifier)
    }

    /// The button that declines: the cancel button's id, else nil.
    public var cancelID: String? { buttons.first { $0.role == "cancel" }?.id }

    /// The push's `ask` field (webviews `cloudStartProgress.ts` `cloudStartAsk`).
    public var json: JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind.rawValue), "title": .string(title),
            "lines": .array(lines.map(JSONValue.string)),
            "buttons": .array(buttons.map { .object(["id": .string($0.id), "title": .string($0.title), "role": .string($0.role)]) }),
        ]
        if let code { value["code"] = .string(code) }
        if let link { value["link"] = .object(["url": .string(link.absoluteString), "title": .string(linkTitle ?? link.host() ?? "")]) }
        return .object(value)
    }
}

/// `cloud.answerStart {key, id, answer}`: the button the person clicked on an ask of start `key`.
public nonisolated struct AgentPaneCloudAnswer: Equatable, Sendable {
    public var key: String
    public var id: String
    public var answer: String

    init?(params: [String: Any]?) {
        guard let key = params?["key"] as? String, UUID(uuidString: key) != nil,
              let id = params?["id"] as? String, (1...64).contains(id.count),
              let answer = params?["answer"] as? String, (1...64).contains(answer.count) else { return nil }
        (self.key, self.id, self.answer) = (key, id, answer)
    }
}

/// The asks a pane's Cloud starts wait on (``AgentPaneModel/cloudAsks``), each until the person
/// answers in the card that shows it. A wait ends as no answer (nil) when its start is cancelled, when
/// the pane closes (``endAll()``), or when the same start asks again: nothing hangs on a card no one
/// can see. A page that loads again has no card for it (``pageReloaded()``): the question moves to its
/// cmux dialog. Each pane owns its own, so only the pane an ask went to can answer it.
@MainActor public final class AgentPaneCloudAsks {
    private struct Waiting {
        let ask: AgentPaneCloudAsk
        let answered: AsyncStream<String>.Continuation
    }

    /// By start key: one ask at a time per start.
    private var waiting: [String: Waiting] = [:]
    /// By start key: the ask whose card went with a page reload; its wait goes on in the fallback's
    /// dialog unless the start ends first (``end(_:)``, ``endAll()``).
    private var moved: [String: String] = [:]
    /// By start key: a moved question's dialog and its ask id, ended with the start's wait.
    private var dialogs: [String: (id: String, task: Task<String?, Never>)] = [:]

    public init() {}

    /// Shows `ask` in start `key`'s card through `push` (the pane's `cloudStartProgress` delivery)
    /// and waits for the button the person clicks; nil when the wait ended with no answer.
    /// `fallback` asks a question whose card a page reload took away (nil: that ends it unanswered).
    public func ask(_ ask: AgentPaneCloudAsk, start key: String, fallback: AgentPaneCloudAsker? = nil,
                    push: @MainActor (JSONValue) -> Void) async -> String? {
        guard !Task.isCancelled else { return nil }
        end(key) // an earlier ask of this start answers nothing now
        let (answers, answered) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        waiting[key] = Waiting(ask: ask, answered: answered)
        push(.object(["key": .string(key), "ask": ask.json]))
        // The stream's iterator ends with nil when the start's task is cancelled: no hop to end it.
        var iterator = answers.makeAsyncIterator()
        let answer = await iterator.next()
        if moved[key] == ask.id {
            moved[key] = nil
            guard let fallback, !Task.isCancelled else { return nil }
            // Its own task, so the pane closing or the start asking again ends the dialog too.
            let dialog = Task { await fallback.ask(ask) }
            dialogs[key] = (ask.id, dialog)
            let shown = await withTaskCancellationHandler { await dialog.value } onCancel: { dialog.cancel() }
            if dialogs[key]?.id == ask.id { dialogs[key] = nil }
            return shown
        }
        if waiting[key]?.ask.id == ask.id { waiting[key] = nil }
        // The card drops the question with the answer, unless the start already asks the next one.
        if waiting[key] == nil { push(.object(["key": .string(key), "ask": .null])) }
        return answer
    }

    /// The person's click on ask `id` of start `key`: false for an ask that is not the one waiting.
    @discardableResult public func answer(_ answer: AgentPaneCloudAnswer) -> Bool {
        guard let found = waiting[answer.key], found.ask.id == answer.id,
              found.ask.buttons.contains(where: { $0.id == answer.answer }) else { return false }
        waiting[answer.key] = nil
        found.answered.yield(answer.answer)
        found.answered.finish()
        return true
    }

    /// Whether the waiting ask of `answer` declines with it (its cancel button): a decline needs no click.
    public func declines(_ answer: AgentPaneCloudAnswer) -> Bool {
        waiting[answer.key].map { $0.ask.id == answer.id && $0.ask.cancelID == answer.answer } ?? false
    }

    /// Ends start `key`'s wait with no answer.
    public func end(_ key: String) {
        waiting.removeValue(forKey: key)?.answered.finish()
        moved[key] = nil
        dialogs.removeValue(forKey: key)?.task.cancel()
    }

    /// The pane's page loaded again: its cards are gone (the page keeps a start's card in its own
    /// state), so every waiting question moves to its dialog, and a click from an old card answers nothing.
    public func pageReloaded() {
        for (key, found) in waiting {
            moved[key] = found.ask.id
            waiting[key] = nil
            found.answered.finish()
        }
    }

    /// The pane closed: every ask it shows ends with no answer.
    public func endAll() {
        for key in Set(waiting.keys).union(dialogs.keys).union(moved.keys) { end(key) }
    }

    /// The asks waiting now (tests).
    var waitingCount: Int { waiting.count }
}

/// Where a Cloud start's questions show: in the sending pane's card (``card(_:start:)``, webviews
/// `CloudStartAsk.tsx`) or, for work with no card to ask in (`cmux cloud start-session`, a chat's
/// credential recovery, Sign In to Codex on a machine), as a cmux dialog (``dialog(_:center:)``).
/// The App decides and words each question; the asker only shows it and returns the clicked button.
public struct AgentPaneCloudAsker: Sendable {
    /// The clicked button's id; nil when the question ended unanswered (dismissed, its start
    /// cancelled, its pane closed, no window to ask in).
    public let ask: @MainActor @Sendable (AgentPaneCloudAsk) async -> String?

    public init(ask: @escaping @MainActor @Sendable (AgentPaneCloudAsk) async -> String?) { self.ask = ask }

    /// In the card of start `key` in the pane `view` that sent it.
    @MainActor public static func card(_ view: AgentPaneView, start key: String) -> AgentPaneCloudAsker {
        AgentPaneCloudAsker { [weak view] question in
            guard let asks = view?.model.cloudAsks else { return nil }
            // A reload takes the card away: the question then asks in a dialog over the pane's window.
            let fallback = AgentPaneCloudAsker.dialog { [weak view] in view?.window.map(CmuxDialogScope.window) }
            return await asks.ask(question, start: key, fallback: fallback) { [weak view] push in
                view?.deliver([AgentPageEvent(kind: "cloudStartProgress", value: push)],
                              scripts: ["window.cmuxAcpmuxBridge?.cloudStartProgress?.(\(push.compactText));"])
            }
        }
    }

    /// As a cmux dialog in `scope` (nil: none to ask in). A question with a link shows it as a button
    /// (``linkButton``) whose answer the caller opens and asks again; the card links to it instead.
    @MainActor public static func dialog(_ scope: @escaping @MainActor @Sendable () -> CmuxDialogScope?,
                                         center: CmuxDialogCenter = .shared) -> AgentPaneCloudAsker {
        AgentPaneCloudAsker { question in
            guard !Task.isCancelled, let target = scope() else { return nil }
            let answers = AsyncStream.makeStream(of: CmuxDialogAnswer.self, bufferingPolicy: .bufferingNewest(1))
            let dialogID = center.present(spec(question), in: target) { answer in
                answers.continuation.yield(answer)
                answers.continuation.finish()
            }
            defer { answers.continuation.finish(); center.dismiss(dialogID) }
            // The iterator ends with nil when the task is cancelled; the defer then dismisses the dialog.
            var iterator = answers.stream.makeAsyncIterator()
            guard let answer = await iterator.next(), !Task.isCancelled, !answer.isDismissal else { return nil }
            return answer.button
        }
    }

    /// The dialog button standing in for the card's link.
    public static let linkButton = "open"

    /// The cmux dialog a question shows as where no card holds it (the debug dialog gallery too).
    public static func spec(_ question: AgentPaneCloudAsk) -> CmuxDialogSpec {
        var buttons = question.buttons.map { button in
            CmuxDialogButton(id: button.id, title: button.title,
                             role: button.role == "default" ? .default : button.role == "cancel" ? .cancel : .normal)
        }
        if question.link != nil {
            // The link's button is the default, as the dialog drew it before the card: open, then confirm.
            buttons = buttons.map { CmuxDialogButton(id: $0.id, title: $0.title, role: $0.role == .default ? .normal : $0.role) }
            buttons.insert(CmuxDialogButton(id: linkButton, title: question.linkTitle ?? linkButton, role: .default), at: min(1, buttons.count))
        }
        return CmuxDialogSpec(title: question.title, lines: question.lines, buttons: buttons, identifier: question.identifier)
    }
}
