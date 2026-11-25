public import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation
import os

/// The page messages Rust decodes (cmux-tui cmux-window-rules `chat::host_op`, its tests the checks' tests): the
/// Cloud environment editor, the Cloud reservation, the Cloud repository actions, the GitHub section and the pane's
/// own messages (lifecycle, paint and pacing reports, composer switches, the shell box, the New Tab page) and the
/// host's small asks (pickers, the quick chat window, dictation, the tab row's tools, toasts, chat links). The host
/// hands Rust the page's message over the app FFI's JSON channel (`window_chat_agent_host_op`) and builds the
/// request from the checked answer; it checks nothing itself. Every other method is still decoded in
/// ``AgentPaneRequest/init(body:)`` until it moves (cmuxterm-hq docs/rfd/drafts/why-swift.md).
extension AgentPaneRequest {
    /// The methods Rust decodes, read once per launch (`window_chat_agent_host_op_methods`).
    nonisolated static let rustHostOpMethods: Set<String> = {
        struct Empty: Encodable {}
        struct Methods: Decodable { var methods: [String] }
        return Set(WindowRules().call("window_chat_agent_host_op_methods", Empty(), as: Methods.self)?.methods ?? [])
    }()

    /// Rust's answer for one page message (`HostOp`): `case` names it, the rest are its fields.
    private nonisolated struct RustHostOp: Decodable {
        struct GitHub: Decodable {
            var request: String
            var repo: String?
            var query: String?
            var candidates: [String]?
            var key: String?
            var url: String?
        }

        var `case`: String
        var method: String?
        var action: String?
        var params: JSONValue?
        var release: Bool?
        var composeKey: String?
        var replacesChat: String?
        var atOpen: Bool?
        var auto: Bool?
        var github: GitHub?
        var pane: Pane?
        var host: Host?
    }

    /// One of the host's own small asks (`host::HostCall`): `op` names it.
    private nonisolated struct Host: Decodable {
        var op: String
        var wait: Bool?
        var sessionId: String?
        var expired: Bool?
        var key: String?
        var onTop: Bool?
        var collapsed: Bool?
        var mode: String?
        var command: String?
        var enabled: Bool?
        var path: String?
        var refresh: Bool?
        var terminalSwitch: Bool?
        var width: Double?
        var need: Double?
        var message: String?
        var isError: Bool?
        var group: String?
        var text: String?
        var x: Double?
        var y: Double?
        var id: String?
        var menuItemId: String?
        var question: String?
        var splitRight: Bool?
        var placement: String?
        var tabId: String?
        var sender: Bool?
        var target: String?
    }

    /// One of the pane's own messages (`pane::PaneOp`): `op` names it.
    private nonisolated struct Pane: Decodable {
        var op: String
        var session: String?
        var reason: String?
        var id: String?
        var text: String?
        var available: Bool?
        var commands: [String]?
        var intervals: [Double]?
        var kind: String?
        var setting: String?
        var show: Bool?
        var on: Bool?
        var ready: Bool?
        var fromKeptTail: Bool?
        var settled: Bool?
        var copy: Bool?
        var live: Bool?
        var epochMs: Double?
        var settledEpochMs: Double?
        var maxMovePx: Double?
        var element: String?
        var shifts: Int?
        var full: Bool?
        var ids: [String]?
        var each: Bool?
        var command: String?
        var cwd: String?
        var after: Int?
        var line: String?
        var token: String?
        var warm: String?
        var template: String?
    }

    /// The request for a page message Rust decodes; `.unsupported(method)` for one it refuses or when the FFI does
    /// not answer.
    nonisolated static func rustHostOp(method: String, params: [String: Any]?) -> AgentPaneRequest {
        let body: [String: Any] = ["method": method, "params": params ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body),
              let answer = WindowRules().callData("window_chat_agent_host_op", data),
              let decoded = try? JSONDecoder().decode(RustHostOp.self, from: answer) else {
            rustHostOpLog.fault("host op \(method, privacy: .public): Rust did not answer")
            return .unsupported(method)
        }
        return request(decoded, method: method) ?? .unsupported(method)
    }

    private nonisolated static func request(_ op: RustHostOp, method: String) -> AgentPaneRequest? {
        switch op.case {
        case "cloudEnvironment":
            guard let action = op.action, let params = op.params else { return nil }
            return .cloudEnvironment(AgentPaneCloudEnvironmentRequest(action: action, params: params))
        case "cloudReservation":
            guard let release = op.release, let params = op.params else { return nil }
            return .cloudReservation(AgentPaneCloudReservationRequest(release: release, params: params, composeKey: op.composeKey,
                                                                      replacesChat: op.replacesChat, atOpen: op.atOpen ?? false,
                                                                      auto: op.auto ?? false))
        case "cloudRepository":
            guard let method = op.method, let params = op.params else { return nil }
            return .cloudRepository(AgentPaneCloudRepositoryRequest(method: method, params: params))
        case "gitHub":
            return op.github.flatMap(gitHub).map(AgentPaneRequest.gitHub)
        case "pane":
            return op.pane.flatMap(pane)
        case "host":
            return op.host.flatMap(host)
        default:
            return nil
        }
    }

    private nonisolated static func gitHub(_ request: RustHostOp.GitHub) -> AgentPaneGitHubRequest? {
        switch request.request {
        case "status": return .status
        case "connect": return .connect(repo: request.repo)
        case "repos": return .repos(query: request.query)
        case "checkout":
            guard let repo = request.repo, let key = request.key else { return nil }
            return .checkout(repo: repo, candidates: request.candidates ?? [], key: key)
        case "cloneUrl":
            guard let url = request.url, let key = request.key else { return nil }
            return .cloneURL(url: url, key: key)
        default: return nil
        }
    }

    private nonisolated static func pane(_ p: Pane) -> AgentPaneRequest? {
        switch p.op {
        case "ready": return .ready
        case "reconnect": return .reconnect
        case "missingChat": return p.session.map { .missingChat(session: $0, reason: p.reason ?? "unknown") }
        case "persistSession": return p.id.map(AgentPaneRequest.persistSession)
        case "cloudStartQueue": return p.text.map(AgentPaneRequest.cloudStartQueue)
        case "unsentDraft": return p.text.map(AgentPaneRequest.unsentDraft)
        case "newChatLeftover": return p.text.map(AgentPaneRequest.newChatLeftover)
        case "newChatLeftoverTaken": return p.text.map(AgentPaneRequest.newChatLeftoverTaken)
        case "checkpointAvailability": return p.available.map(AgentPaneRequest.checkpointAvailability)
        case "commandAvailability": return p.commands.map(AgentPaneRequest.commandAvailability)
        case "framePacing": return p.intervals.map(AgentPaneRequest.framePacing)
        case "finishSound": return p.kind.flatMap(AgentPaneFinishSound.Kind.init(rawValue:)).map(AgentPaneRequest.finishSound)
        case "composerSetting":
            guard let show = p.show else { return nil }
            switch p.setting {
            case "showDictation": return .composerSetting(path: AgentPaneComposerSetting.showDictationPath, show: show)
            case "scrollToBottomOnSend": return .composerSetting(path: AgentPaneComposerSetting.scrollToBottomOnSendPath, show: show)
            case "showContextUsage": return .composerSetting(path: AgentPaneComposerSetting.showContextUsagePath, show: show)
            default: return nil
            }
        case "remoteControl": return p.on.map { .remoteControl(on: $0) }
        case "paneNoticeAction": return p.id.map { .paneNoticeAction(id: $0) }
        case "clientReady": return p.ready.map(AgentPaneRequest.clientReady)
        case "painted":
            return .painted(fromKeptTail: p.fromKeptTail ?? false, settled: p.settled ?? false, copy: p.copy ?? false, live: p.live ?? false)
        case "inputEchoed": return p.epochMs.map { .inputEchoed(at: Date(timeIntervalSince1970: $0 / 1_000)) }
        case "launchSettle":
            guard let ms = p.settledEpochMs, let px = p.maxMovePx, let shifts = p.shifts else { return nil }
            return .launchSettle(settledAt: Date(timeIntervalSince1970: ms / 1_000), maxMovePx: px, element: p.element ?? "other", shifts: shifts)
        case "renderRate": return p.full.map(AgentPaneRequest.renderRate)
        case "typeAhead": return p.text.map(AgentPaneRequest.typeAhead)
        case "harnessUpdate":
            guard let ids = p.ids, let each = p.each else { return nil }
            return .harnessUpdate(ids: ids, each: each)
        case "restartAcpmux": return .restartAcpmux
        case "harnessRestart": return .harnessRestart
        case "shellRun": return p.command.map { .shellRun(command: $0, cwd: p.cwd) }
        case "shellRead":
            guard let id = p.id, let after = p.after else { return nil }
            return .shellRead(id: id, after: after)
        case "shellComplete": return p.line.map { .shellComplete(line: $0, cwd: p.cwd) }
        case "shellStop": return p.id.map { .shellStop(id: $0) }
        case "newTabInputReady": return p.token.map(AgentPaneRequest.newTabInputReady)
        case "touched": return .touched
        case "newTabContext": return .newTabContext
        case "newTabCloudPick": return .newTabCloudPick
        case "newTabWarm": return p.warm.map(AgentPaneRequest.newTabWarm)
        case "newTabTemplate": return p.template.map { .editNewTab(.template($0)) }
        default: return nil
        }
    }

    private nonisolated static func host(_ h: Host) -> AgentPaneRequest? {
        switch h.op {
        case "browseProject": return .browseProject
        case "sandboxState": return .sandboxState(wait: h.wait ?? false)
        case "cloudHandoffTurn": return h.sessionId.map { .cloudHandoffTurn(sessionId: $0) }
        case "cloudSignInCancel": return .cloudSignInCancel(expired: h.expired ?? false)
        case "cloudSignIn": return h.key.map { .cloudSignIn(key: $0) }
        case "cloudSetupState": return .cloudSetupState
        case "chooseFolder": return .chooseFolder
        case "chooseChatFolder": return .chooseChatFolder
        case "shareMachineWithMe": return .shareMachineWithMe
        case "chooseAttachments": return .chooseAttachments
        case "attachExternal": return .attachExternal
        case "editorsList": return .editorsList
        case "quickDismiss": return .quickDismiss
        case "quickOpenInWindow": return .quickOpenInWindow(sessionId: h.sessionId)
        case "quickSetOnTop": return h.onTop.map(AgentPaneRequest.quickSetOnTop)
        case "quickSetCollapsed": return h.collapsed.map(AgentPaneRequest.quickSetCollapsed)
        case "quickFloatingState": return .quickFloatingState
        case "quickContext": return .quickContext
        case "composerCapture": return .composerCapture(mode: h.mode)
        case "transportOpen": return .transportOpen
        case "transportGestureRelease": return .transportGestureRelease
        case "dictation":
            switch h.command {
            case "toggle": return .dictation(.toggle)
            case "start": return .dictation(.start)
            case "stop": return .dictation(.stop)
            case "cancel": return .dictation(.cancel)
            default: return nil
            }
        case "dictationHandoff": return .dictationHandoff
        case "dictationSources": return .dictationSources
        case "dictationRecordAudio": return h.enabled.map { .dictation(.recordAudio($0)) }
        case "dictationRecordingUpload": return h.path.map { .dictationRecordingUpload(path: $0) }
        case "dictationRecordingCancel": return h.path.map { .dictationRecordingCancel(path: $0) }
        case "tabState": return .tabState(refresh: h.refresh ?? false, terminalSwitch: h.terminalSwitch ?? false)
        case "tabRowTools": return h.width.map { .tabRowTools(width: $0, need: h.need) }
        case "toast": return h.message.map { .toast(message: $0, isError: h.isError ?? false, group: h.group) }
        case "copyText": return h.text.map(AgentPaneRequest.copyText)
        case "customizationsMenu":
            guard let x = h.x, let y = h.y else { return nil }
            return .customizationsMenu(x: x, y: y)
        case "tabRowToolsOpenMenu": return h.id.map { .tabRowToolsOpenMenu(id: $0, menuItemID: h.menuItemId) }
        case "btwInline":
            guard let question = h.question, let session = h.sessionId else { return nil }
            return .btwInline(question: question, sessionId: session)
        case "sideChat": return h.sessionId.map { .sideChat($0, splitRight: h.splitRight ?? false) }
        case "chatTab": return h.sessionId.map { .chatTab($0, AgentForkDestination(placement: h.placement)) }
        case "attentionOpen": return h.tabId.map(AgentPaneRequest.attentionOpen)
        case "offerOpen": return h.sessionId.map { .offerOpen($0, sender: h.sender ?? false) }
        case "jump":
            guard let target = h.target.flatMap(AgentPaneJumpTarget.init(rawValue:)), let id = h.id else { return nil }
            return .jump(target, id: id)
        default: return nil
        }
    }

    private nonisolated static let rustHostOpLog = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane")
}
